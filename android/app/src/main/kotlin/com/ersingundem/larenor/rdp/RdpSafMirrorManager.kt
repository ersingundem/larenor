package com.ersingundem.larenor.rdp

import android.net.Uri
import android.os.CancellationSignal
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.text.Normalizer
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

internal data class RdpSafActiveGrant(
    val authorityId: String,
    val grantId: String,
    val grantRevision: Long,
    val treeUri: Uri,
)

internal data class RdpSafExactSession(
    val requestId: String,
    val revision: Long,
)

internal data class RdpSafNativeCloseReceipt(
    val transferId: String,
    val sessionRequestId: String,
    val sessionRevision: Long,
    val receiptId: String,
    val nativeWritersClosed: Boolean,
)

internal interface RdpSafNativeDrain {
    fun close(
        identity: RdpSafTransferIdentity,
        callback: (Result<RdpSafNativeCloseReceipt>) -> Unit,
    )
}

internal sealed interface RdpSafMirrorResult {
    data class Prepared(val transferId: String, val mirrorRoot: File) : RdpSafMirrorResult
    data class Sealed(val transferId: String, val files: Int) : RdpSafMirrorResult
    data class Saved(val transferId: String, val files: Int) : RdpSafMirrorResult
    data object Unknown : RdpSafMirrorResult
    data class Failure(val code: String) : RdpSafMirrorResult
}

/**
 * Owns a single transfer. Every method is asynchronous and serialized. A timed-out provider call
 * may still complete externally, so timeout makes the journal UNKNOWN and permanently blocks this
 * manager from starting another transfer or replaying the effect.
 */
internal class RdpSafMirrorManager(
    private val privateRoot: File,
    private val journal: RdpSafTransferJournal,
    private val documents: RdpSafDocumentsPort,
    private val nativeDrain: RdpSafNativeDrain,
    private val processEpoch: String,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor(),
    private val deadlines: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(),
    private val operationTimeoutMs: Long = 35_000,
    private val sealOverride: ((File, CancellationSignal) -> List<RdpSafSealedFile>)? = null,
) : AutoCloseable {
    private val generation = AtomicLong(0)
    private val operationLock = Any()
    private var activeGeneration: Long? = null
    private var activeIdentity: RdpSafTransferIdentity? = null
    private var activeCancel: CancellationSignal? = null
    private var pendingNativeCallbacks = 0
    private var nativeCallbacksIdle: CountDownLatch? = null
    private var ownerReleaseForbidden = false
    @Volatile private var closed = false

    fun prepare(
        identity: RdpSafTransferIdentity,
        grant: RdpSafActiveGrant,
        callback: (RdpSafMirrorResult) -> Unit,
    ) {
        if (!authorityMatches(identity, grant) || identity.processEpoch != processEpoch) {
            callback(RdpSafMirrorResult.Failure("authority_changed"))
            return
        }
        submit(identity, callback) { cancel, current ->
            journal.requirePrepareAllowed(identity)
            val transferRoot = File(privateRoot, identity.transferId)
            val drive = File(transferRoot, ROOT_DIRECTORY)
            val toRemote = File(drive, RdpSafDocumentsAdapter.TO_REMOTE)
            val fromRemote = File(drive, RdpSafDocumentsAdapter.FROM_REMOTE)
            createPrivateDirectory(privateRoot)
            createPrivateDirectory(transferRoot)
            createPrivateDirectory(drive)
            createPrivateDirectory(toRemote)
            createPrivateDirectory(fromRemote)
            journal.create(identity, drive)
            val staged = documents.snapshotToRemote(grant.treeUri, toRemote, cancel)
            requireCurrent(current, cancel)
            journal.prepared(identity, staged)
            RdpSafMirrorResult.Prepared(identity.transferId, drive)
        }
    }

    fun closeAndSeal(
        identity: RdpSafTransferIdentity,
        callback: (RdpSafMirrorResult) -> Unit,
    ) {
        if (closed) {
            callback(RdpSafMirrorResult.Failure("unavailable"))
            return
        }
        val cancel = CancellationSignal()
        val current = reserve(identity, cancel) ?: run {
            callback(RdpSafMirrorResult.Failure(if (closed) "unavailable" else "busy"))
            return
        }
        val resultDelivered = AtomicBoolean(false)
        fun publish(value: RdpSafMirrorResult) {
            if (resultDelivered.compareAndSet(false, true)) callback(value)
        }
        // The deadline owns the complete close transaction, including the
        // durable close intent. A blocked journal write must not leave the
        // process-wide transfer owner reserved forever.
        val timeout = deadlines.schedule({
            if (finishUnknown(current, identity, cancel)) {
                publish(RdpSafMirrorResult.Unknown)
            }
        }, operationTimeoutMs, TimeUnit.MILLISECONDS)
        executor.execute {
            try {
                journal.closeRequested(identity)
            } catch (_: Exception) {
                if (finish(current)) {
                    timeout.cancel(false)
                    publish(RdpSafMirrorResult.Failure("unavailable"))
                }
                return@execute
            }
            val callbackEnded = AtomicBoolean(true)
            fun endCallbackOnce() {
                if (callbackEnded.compareAndSet(false, true)) endNativeCallback()
            }
            try {
                if (!beginNativeCallback(current)) return@execute
                callbackEnded.set(false)
                val delivered = AtomicBoolean(false)
                nativeDrain.close(identity) { outcome ->
                    if (!delivered.compareAndSet(false, true)) return@close
                    try {
                        runCatching {
                            executor.execute complete@{
                                if (!isCurrent(current)) return@complete
                                val receipt = outcome.getOrElse {
                                    if (finishUnknown(current, identity, cancel)) {
                                        timeout.cancel(false)
                                        publish(RdpSafMirrorResult.Unknown)
                                    }
                                    return@complete
                                }
                                if (!receipt.nativeWritersClosed || receipt.transferId != identity.transferId ||
                                    receipt.sessionRequestId != identity.sessionRequestId ||
                                    receipt.sessionRevision != identity.sessionRevision
                                ) {
                                    if (finishUnknown(current, identity, cancel)) {
                                        timeout.cancel(false)
                                        publish(RdpSafMirrorResult.Unknown)
                                    }
                                    return@complete
                                }
                                try {
                                    val record = journal.read(identity)
                                    val fromRemote = File(record.mirrorRoot, RdpSafDocumentsAdapter.FROM_REMOTE)
                                    val sealed = sealOverride?.invoke(fromRemote, cancel)
                                        ?: sealPrivateDirectory(fromRemote, cancel)
                                    val updated = journal.sealed(identity, receipt.receiptId, sealed)
                                    if (finish(current)) {
                                        timeout.cancel(false)
                                        publish(RdpSafMirrorResult.Sealed(identity.transferId, updated.fromRemote.size))
                                    }
                                } catch (_: Exception) {
                                    if (finishUnknown(current, identity, cancel)) {
                                        timeout.cancel(false)
                                        publish(RdpSafMirrorResult.Unknown)
                                    }
                                }
                            }
                        }
                    } finally {
                        endCallbackOnce()
                    }
                }
            } catch (_: Exception) {
                endCallbackOnce()
                if (finishUnknown(current, identity, cancel)) {
                    timeout.cancel(false)
                    publish(RdpSafMirrorResult.Unknown)
                }
            }
        }
    }

    /** This is the only path that may create or write provider documents. */
    fun saveReceived(
        identity: RdpSafTransferIdentity,
        grant: RdpSafActiveGrant,
        callback: (RdpSafMirrorResult) -> Unit,
    ) {
        if (!authorityMatches(identity, grant)) {
            callback(RdpSafMirrorResult.Failure("authority_changed"))
            return
        }
        submit(identity, callback) { cancel, current ->
            var record = journal.read(identity)
            if (record.phase == RdpSafTransferPhase.COMPLETE) {
                return@submit RdpSafMirrorResult.Saved(identity.transferId, record.fromRemote.size)
            }
            if (record.phase != RdpSafTransferPhase.SEALED) unavailable()
            if (record.fromRemote.isEmpty()) {
                record = journal.completeEmpty(identity)
                return@submit RdpSafMirrorResult.Saved(identity.transferId, 0)
            }
            for (file in record.fromRemote.sortedBy { it.name }) {
                requireCurrent(current, cancel)
                if (file.phase == RdpSafFileCommitPhase.SAF_VERIFIED) continue
                if (file.phase != RdpSafFileCommitPhase.SEALED_PRIVATE) unavailable()
                journal.beginFileCommit(identity, file.name)
                val candidate = documents.inspectSaveCandidate(grant.treeUri, file.name, cancel)
                if (candidate !is RdpSafCandidateSet.None) {
                    journal.fileUnknown(identity, file.name)
                    return@submit RdpSafMirrorResult.Unknown
                }
                journal.createDispatched(identity, file.name)
                val created = try {
                    documents.createForSave(grant.treeUri, file.name, cancel)
                } catch (_: Exception) {
                    journal.fileUnknown(identity, file.name)
                    return@submit RdpSafMirrorResult.Unknown
                }
                requireCurrent(current, cancel)
                journal.created(identity, file.name, created.uri.toString())
                journal.writeDispatched(identity, file.name)
                val sealed = file.sealed()
                try {
                    documents.writeOnce(created, sealed, cancel)
                } catch (_: Exception) {
                    journal.fileUnknown(identity, file.name)
                    return@submit RdpSafMirrorResult.Unknown
                }
                requireCurrent(current, cancel)
                if (!documents.readback(created, sealed, cancel)) {
                    journal.fileUnknown(identity, file.name)
                    return@submit RdpSafMirrorResult.Unknown
                }
                record = journal.verified(identity, file.name)
            }
            RdpSafMirrorResult.Saved(identity.transferId, record.fromRemote.size)
        }
    }

    /**
     * Recovery is readback-only for dispatched provider effects. It never creates, writes, or
     * overwrites a document. A zero/multiple candidate result remains UNKNOWN.
     */
    fun recoverDispatchedSave(
        identity: RdpSafTransferIdentity,
        grant: RdpSafActiveGrant,
        callback: (RdpSafMirrorResult) -> Unit,
    ) {
        if (!authorityMatches(identity, grant)) {
            callback(RdpSafMirrorResult.Failure("authority_changed"))
            return
        }
        submit(identity, callback, allowUnknown = true) { cancel, current ->
            val record = journal.read(identity)
            val unresolved = record.fromRemote.filter {
                it.phase in setOf(
                    RdpSafFileCommitPhase.SAF_CREATE_DISPATCHED,
                    RdpSafFileCommitPhase.SAF_CREATED,
                    RdpSafFileCommitPhase.SAF_WRITE_DISPATCHED,
                    RdpSafFileCommitPhase.UNKNOWN,
                )
            }
            if (unresolved.isEmpty()) return@submit RdpSafMirrorResult.Unknown
            var recovered = record
            for (file in unresolved) {
                requireCurrent(current, cancel)
                val candidate = documents.inspectSaveCandidate(grant.treeUri, file.name, cancel)
                if (candidate !is RdpSafCandidateSet.One ||
                    file.providerUri != null && candidate.document.uri.toString() != file.providerUri ||
                    !documents.readback(candidate.document, file.sealed(), cancel)
                ) return@submit RdpSafMirrorResult.Unknown
                recovered = journal.recoveredVerified(
                    identity,
                    file.name,
                    candidate.document.uri.toString(),
                )
            }
            if (recovered.phase == RdpSafTransferPhase.COMPLETE) {
                RdpSafMirrorResult.Saved(identity.transferId, recovered.fromRemote.size)
            } else {
                RdpSafMirrorResult.Sealed(identity.transferId, recovered.fromRemote.size)
            }
        }
    }

    fun discardAfterClose(
        identity: RdpSafTransferIdentity,
        callback: (RdpSafMirrorResult) -> Unit,
    ) {
        submit(identity, callback) { cancel, current ->
            val intent = journal.beginDiscard(identity)
            requireCurrent(current, cancel)
            val mirror = File(intent.mirrorRoot)
            deletePrivateTree(mirror, cancel)
            journal.discarded(identity)
            journal.clearTerminal(identity)
            RdpSafMirrorResult.Saved(identity.transferId, 0)
        }
    }

    /**
     * Removes only the private mirror after every provider write has a durable verified readback.
     * The authenticated DISCARDED terminal record is retained so a lost public save receipt can
     * be reconciled without replaying provider I/O.
     */
    fun cleanupAfterSave(
        identity: RdpSafTransferIdentity,
        callback: (RdpSafMirrorResult) -> Unit,
    ) {
        submit(identity, callback) { cancel, current ->
            val record = journal.read(identity)
            if (record.phase == RdpSafTransferPhase.DISCARDED) {
                return@submit RdpSafMirrorResult.Saved(identity.transferId, record.fromRemote.size)
            }
            if (record.phase !in setOf(
                    RdpSafTransferPhase.COMPLETE,
                    RdpSafTransferPhase.DISCARD_INTENT,
                )
            ) unavailable()
            val intent = if (record.phase == RdpSafTransferPhase.COMPLETE) {
                journal.beginDiscard(identity)
            } else {
                record
            }
            requireCurrent(current, cancel)
            val mirror = File(intent.mirrorRoot)
            if (mirror.exists()) {
                deletePrivateTree(mirror, cancel)
            } else if (java.nio.file.Files.isSymbolicLink(mirror.toPath())) {
                unavailable()
            }
            val transferRoot = mirror.parentFile ?: unavailable()
            if (transferRoot.exists()) {
                requirePrivateDirectory(transferRoot)
                if (transferRoot.list()?.isNotEmpty() != false || !transferRoot.delete()) unavailable()
            } else if (java.nio.file.Files.isSymbolicLink(transferRoot.toPath())) {
                unavailable()
            }
            val terminal = journal.discarded(identity)
            RdpSafMirrorResult.Saved(identity.transferId, terminal.fromRemote.size)
        }
    }

    override fun close() {
        closeAndAwaitQuiescence(0)
    }

    /**
     * Cancels owned work and confirms that no local provider call can still be executing. A false
     * result must retain the process owner until process death; it is never upgraded asynchronously.
     */
    fun closeAndAwaitQuiescence(timeoutMs: Long): Boolean {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(0))
        val nativeIdle = synchronized(operationLock) {
            closed = true
            if (activeGeneration != null || pendingNativeCallbacks != 0) {
                ownerReleaseForbidden = true
            }
            activeCancel?.cancel()
            activeIdentity?.let { runCatching { journal.markUnknown(it) } }
            activeGeneration = null
            activeIdentity = null
            activeCancel = null
            nativeCallbacksIdle
        }
        var nativeIdleConfirmed = true
        if (nativeIdle != null) {
            val remaining = (deadline - System.nanoTime()).coerceAtLeast(0)
            nativeIdleConfirmed = try {
                nativeIdle.await(remaining, TimeUnit.NANOSECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                false
            }
        }
        // Always stop both owned executors. Missing callback quiescence keeps the process owner
        // reserved, but it must not also leak live non-daemon executor threads or deadline tasks.
        executor.shutdownNow()
        deadlines.shutdownNow()
        if (timeoutMs <= 0) return nativeIdleConfirmed &&
            executor.isTerminated && deadlines.isTerminated && synchronized(operationLock) {
                !ownerReleaseForbidden
            }
        val executorRemaining = (deadline - System.nanoTime()).coerceAtLeast(0)
        val executorDone = runCatching {
            executor.awaitTermination(executorRemaining, TimeUnit.NANOSECONDS)
        }.getOrDefault(false)
        val remaining = (deadline - System.nanoTime()).coerceAtLeast(0)
        val deadlinesDone = runCatching {
            deadlines.awaitTermination(remaining, TimeUnit.NANOSECONDS)
        }.getOrDefault(false)
        return nativeIdleConfirmed && executorDone && deadlinesDone && synchronized(operationLock) {
            !ownerReleaseForbidden
        }
    }

    private fun beginNativeCallback(expected: Long): Boolean = synchronized(operationLock) {
        if (closed || activeGeneration != expected) return@synchronized false
        if (pendingNativeCallbacks == 0) nativeCallbacksIdle = CountDownLatch(1)
        pendingNativeCallbacks++
        true
    }

    private fun endNativeCallback() = synchronized(operationLock) {
        if (pendingNativeCallbacks > 0) pendingNativeCallbacks--
        if (pendingNativeCallbacks == 0) {
            nativeCallbacksIdle?.countDown()
            nativeCallbacksIdle = null
        }
    }

    private fun submit(
        identity: RdpSafTransferIdentity,
        callback: (RdpSafMirrorResult) -> Unit,
        allowUnknown: Boolean = false,
        block: (CancellationSignal, Long) -> RdpSafMirrorResult,
    ) {
        if (closed) {
            callback(RdpSafMirrorResult.Failure("unavailable"))
            return
        }
        val cancel = CancellationSignal()
        val current = reserve(identity, cancel) ?: run {
            callback(RdpSafMirrorResult.Failure(if (closed) "unavailable" else "busy"))
            return
        }
        val resultDelivered = AtomicBoolean(false)
        fun publish(value: RdpSafMirrorResult) {
            if (resultDelivered.compareAndSet(false, true)) callback(value)
        }
        val timeout = deadlines.schedule({
            if (finishUnknown(current, identity, cancel)) {
                publish(RdpSafMirrorResult.Unknown)
            }
        }, operationTimeoutMs, TimeUnit.MILLISECONDS)
        executor.execute {
            try {
                if (!allowUnknown && journal.runCatchingRead(identity)?.phase == RdpSafTransferPhase.UNKNOWN) {
                    unavailable()
                }
                val result = block(cancel, current)
                if (finish(current)) {
                    timeout.cancel(false)
                    publish(result)
                }
            } catch (_: Exception) {
                if (finishUnknown(current, identity, cancel)) {
                    timeout.cancel(false)
                    publish(RdpSafMirrorResult.Unknown)
                }
            }
        }
    }

    private fun authorityMatches(identity: RdpSafTransferIdentity, grant: RdpSafActiveGrant) =
        identity.authorityId == grant.authorityId && identity.grantId == grant.grantId &&
            identity.grantRevision == grant.grantRevision

    private fun requireCurrent(expected: Long, cancel: CancellationSignal) {
        cancel.throwIfCanceled()
        if (closed || synchronized(operationLock) { activeGeneration != expected }) unavailable()
    }

    private fun reserve(identity: RdpSafTransferIdentity, cancel: CancellationSignal): Long? =
        synchronized(operationLock) {
        if (closed || activeGeneration != null) return@synchronized null
        generation.incrementAndGet().also {
            activeGeneration = it
            activeIdentity = identity
            activeCancel = cancel
        }
    }

    private fun finish(expected: Long): Boolean = synchronized(operationLock) {
        if (activeGeneration != expected) return@synchronized false
        activeGeneration = null
        activeIdentity = null
        activeCancel = null
        true
    }

    private fun isCurrent(expected: Long): Boolean = synchronized(operationLock) {
        !closed && activeGeneration == expected
    }

    /** Persist UNKNOWN before releasing the single-flight slot; persistence failure keeps it busy. */
    private fun finishUnknown(
        expected: Long,
        identity: RdpSafTransferIdentity,
        cancel: CancellationSignal,
    ): Boolean = synchronized(operationLock) {
        if (activeGeneration != expected) return@synchronized false
        cancel.cancel()
        val durable = runCatching {
            val phase = journal.read(identity).phase
            if (phase !in setOf(
                    RdpSafTransferPhase.COMPLETE,
                    RdpSafTransferPhase.DISCARD_INTENT,
                )
            ) journal.markUnknown(identity)
        }.isSuccess
        if (durable) {
            activeGeneration = null
            activeIdentity = null
            activeCancel = null
        }
        true
    }

    private fun sealPrivateDirectory(directory: File, cancel: CancellationSignal): List<RdpSafSealedFile> {
        requirePrivateDirectory(directory)
        val entries = directory.listFiles()?.toList() ?: unavailable()
        if (entries.size > RdpSafDocumentsAdapter.MAX_FILES) unavailable()
        val names = entries.map { Normalizer.normalize(it.name, Normalizer.Form.NFC) }
        if (names.toSet().size != names.size) unavailable()
        var total = 0L
        return entries.sortedBy { it.name }.map { file ->
            cancel.throwIfCanceled()
            validateName(file.name)
            requirePrivateFile(file, directory)
            val digest = MessageDigest.getInstance("SHA-256")
            var size = 0L
            FileInputStream(file).use { input ->
                val buffer = ByteArray(BUFFER_BYTES)
                while (true) {
                    cancel.throwIfCanceled()
                    val read = input.read(buffer)
                    if (read < 0) break
                    size = Math.addExact(size, read.toLong())
                    if (size > RdpSafDocumentsAdapter.MAX_FILE_BYTES) unavailable()
                    digest.update(buffer, 0, read)
                }
                buffer.fill(0)
            }
            total = Math.addExact(total, size)
            if (total > RdpSafDocumentsAdapter.MAX_TOTAL_BYTES) unavailable()
            RdpSafSealedFile(file.name, size, digest.digest().hex(), file)
        }
    }

    private fun createPrivateDirectory(value: File) {
        if (!value.exists() && !value.mkdir()) unavailable()
        requirePrivateDirectory(value)
        value.setReadable(false, false)
        value.setWritable(false, false)
        value.setExecutable(false, false)
        if (!value.setReadable(true, true) || !value.setWritable(true, true) ||
            !value.setExecutable(true, true)
        ) unavailable()
    }

    private fun requirePrivateDirectory(value: File) {
        if (!value.isDirectory || java.nio.file.Files.isSymbolicLink(value.toPath()) ||
            java.nio.file.Files.getAttribute(value.toPath(), "unix:nlink") !is Number
        ) unavailable()
    }

    private fun requirePrivateFile(value: File, parent: File) {
        if (value.parentFile?.canonicalFile != parent.canonicalFile || !value.isFile ||
            java.nio.file.Files.isSymbolicLink(value.toPath()) ||
            (java.nio.file.Files.getAttribute(value.toPath(), "unix:nlink") as Number).toLong() != 1L
        ) unavailable()
    }

    private fun validateName(value: String) {
        if (value.toByteArray(Charsets.UTF_8).size !in 1..RdpSafDocumentsAdapter.MAX_NAME_BYTES ||
            value in setOf(".", "..") ||
            value.any { it == '\u0000' || it == '/' || it == '\\' || it.code < 0x20 || it.code == 0x7f }
        ) unavailable()
    }

    private fun deletePrivateTree(root: File, cancel: CancellationSignal) {
        requirePrivateDirectory(root)
        root.walkBottomUp().forEach {
            cancel.throwIfCanceled()
            if (java.nio.file.Files.isSymbolicLink(it.toPath()) || !it.delete()) unavailable()
        }
    }

    private fun RdpSafTransferFileRecord.sealed() = RdpSafSealedFile(
        name = name,
        size = size,
        sha256 = sha256,
        file = File(privatePath),
    )

    private fun RdpSafTransferJournal.runCatchingRead(identity: RdpSafTransferIdentity) =
        runCatching { read(identity) }.getOrNull()

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun unavailable(): Nothing = throw IllegalStateException("saf_transfer_unavailable")

    companion object {
        const val DRIVE_NAME = "LrnXfer"
        const val ROOT_DIRECTORY = "root"
        private const val BUFFER_BYTES = 64 * 1024
    }
}
