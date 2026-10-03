package com.ersingundem.larenor.rdp

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.TimeUnit

/** One transfer coordinator may own provider effects in this process at a time. */
internal class RdpSafProcessOwner(val processEpoch: String) {
    private val lock = Any()
    private var owner: Any? = null

    init {
        require(processEpoch.matches(Regex("[0-9a-f]{32}")))
    }

    fun tryAcquire(token: Any): Boolean = synchronized(lock) {
        if (owner != null && owner !== token) return@synchronized false
        owner = token
        true
    }

    fun release(token: Any) = synchronized(lock) {
        if (owner === token) owner = null
    }
}

private object RdpSafProductionProcessOwner {
    val value = RdpSafProcessOwner(
        ByteArray(16).also(SecureRandom()::nextBytes).joinToString("") { "%02x".format(it) },
    )
}

/**
 * Joins the schema-5 grant owner, schema-6 transfer journal, and the exact opened RDP session.
 * Provider URIs and mirror paths remain native-only. Transport cancellation never seals a mirror.
 */
internal class RdpSafTransferCoordinator(
    activity: Activity,
    private val grants: RdpSafGrantBroker,
    private val foreground: () -> Boolean,
    private val clearSession: (RdpNativeSession) -> Unit,
    private val main: Handler = Handler(Looper.getMainLooper()),
    private val randomHex: () -> String = {
        ByteArray(16).also(SecureRandom()::nextBytes).joinToString("") { "%02x".format(it) }
    },
    processEpochOverride: String? = null,
    journalOverride: RdpSafTransferJournal? = null,
    managerOverride: RdpSafMirrorManager? = null,
    grantResolverOverride: ((RdpSafAuthority, String, Long) -> RdpSafActiveGrant)? = null,
    coldGrantResolverOverride: ((RdpSafTransferIdentity) -> RdpSafActiveGrant)? = null,
    processOwnerOverride: RdpSafProcessOwner? = null,
    private val processOwnerCloseWaitMs: Long = PROCESS_OWNER_CLOSE_WAIT_MS,
) : AutoCloseable {
    private val lock = Any()
    private val processOwner = processOwnerOverride ?: processEpochOverride?.let(::RdpSafProcessOwner)
        ?: RdpSafProductionProcessOwner.value
    private val processEpoch = processOwner.processEpoch.also(::requireHex32)
    private val processOwnerToken = Any()
    private var ownsProcess = processOwner.tryAcquire(processOwnerToken)
    private val journal = journalOverride
        ?: RdpSafTransferJournal(RdpSafEncryptedTransferStore(activity))
    private val manager = managerOverride ?: RdpSafMirrorManager(
        privateRoot = File(activity.noBackupFilesDir, MIRROR_DIRECTORY),
        journal = journal,
        documents = RdpSafDocumentsAdapter(activity.contentResolver),
        nativeDrain = object : RdpSafNativeDrain {
            override fun close(
                identity: RdpSafTransferIdentity,
                callback: (Result<RdpSafNativeCloseReceipt>) -> Unit,
            ) = drainExactSession(identity, callback)
        },
        processEpoch = processEpoch,
    )
    private val grantResolver = grantResolverOverride ?: {
            authority: RdpSafAuthority, grantId: String, grantRevision: Long ->
        val resolved = grants.resolveActiveGrant(authority, grantId, grantRevision)
        RdpSafActiveGrant(
            resolved.authorityId,
            resolved.grantId,
            resolved.grantRevision,
            resolved.treeUri,
        )
    }
    private val coldGrantResolver = coldGrantResolverOverride ?: { identity: RdpSafTransferIdentity ->
        val record = RdpSafGrantStore(activity).read().singleOrNull {
            it.authority.authorityId == identity.authorityId &&
                it.grantId == identity.grantId &&
                it.grantRevision == identity.grantRevision
        } ?: throw RdpSafFailure("authority_changed")
        if (record.phase != RdpSafGrantPhase.ACTIVE) throw RdpSafFailure("authority_changed")
        val treeUri = record.uri?.let(Uri::parse) ?: throw RdpSafFailure("unavailable")
        val permission = activity.contentResolver.persistedUriPermissions.singleOrNull {
            it.uri == treeUri
        } ?: throw RdpSafFailure("permission_denied")
        val persisted =
            (if (permission.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                (if (permission.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
        if (persisted and RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS !=
            RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS
        ) throw RdpSafFailure("permission_denied")
        RdpSafActiveGrant(
            record.authority.authorityId,
            record.grantId,
            record.grantRevision,
            treeUri,
        )
    }

    private val initialSnapshot = runCatching { journal.snapshot() }
    private var coldReadbackAllowed = ownsProcess && initialSnapshot.getOrNull()?.let {
        it.identity.processEpoch != processEpoch
    } == true
    private val recovery = if (ownsProcess) runCatching { journal.recover(processEpoch) }
        else initialSnapshot
    private var recovered = recovery.getOrNull()
    private var currentIdentity: RdpSafTransferIdentity? = recovered?.identity
    private var currentMirrorRoot: String? = recovered?.mirrorRoot
    private var openedSession: RdpNativeSession? = null
    private var drainingIdentity: RdpSafTransferIdentity? = null
    private var stickyUnknown = !ownsProcess || recovery.isFailure ||
        recovered?.let(::requiresReadbackRecovery) == true
    private var coldRecoveryInFlight = false
    private var coldRecoveryScheduled = false
    private val coldRecoveryDeadline = SystemClock.elapsedRealtime() + COLD_RECOVERY_WINDOW_MS
    private val coldRecovery = Runnable {
        synchronized(lock) { coldRecoveryScheduled = false }
        attemptColdRecovery()
    }
    private var disposed = false

    init {
        require(processOwnerCloseWaitMs in 1..MAX_PROCESS_OWNER_CLOSE_WAIT_MS)
        if (stickyUnknown) scheduleColdRecovery(0)
    }

    fun prepare(raw: Any?, result: MethodChannel.Result) {
        triggerColdRecovery()
        val request = parse(result) { RdpFileTransferContract.prepare(raw) } ?: return
        if (!ensureProcessOwnership()) return error(result, "busy")
        if (!foreground()) return error(result, "foregroundRequired")
        val grant = resolve(request.authority, request.grantId, request.grantRevision, result) ?: return
        val identity = synchronized(lock) {
            if (disposed || stickyUnknown || currentIdentity?.let { !terminal(it) } == true) {
                return error(result, if (disposed) "engineUnavailable" else "busy")
            }
            RdpSafTransferIdentity(
                transferId = randomHex().also(::requireHex32),
                authorityId = request.authority.authorityId,
                grantId = request.grantId,
                grantRevision = request.grantRevision,
                sessionRequestId = request.sessionRequestId,
                sessionRevision = request.sessionRevision,
                processEpoch = processEpoch,
            ).also {
                currentIdentity = it
                currentMirrorRoot = null
                recovered = null
                openedSession = null
                drainingIdentity = null
                stickyUnknown = false
            }
        }
        manager.prepare(identity, grant) { outcome ->
            main.post {
                if (disposed || !foreground()) {
                    markUnknown(identity)
                    return@post error(result, "foregroundRequired")
                }
                when (outcome) {
                    is RdpSafMirrorResult.Prepared -> {
                        synchronized(lock) {
                            if (currentIdentity != identity || stickyUnknown) {
                                return@post error(result, "staleSession")
                            }
                            currentMirrorRoot = outcome.mirrorRoot.canonicalPath
                        }
                        result.success(receipt(request.requestId, identity, "prepared"))
                    }
                    RdpSafMirrorResult.Unknown -> {
                        markUnknown(identity)
                        error(result, "connectionFailed")
                    }
                    is RdpSafMirrorResult.Failure -> error(result, failureCode(outcome.code))
                    else -> error(result, "connectionFailed")
                }
            }
        }
    }

    fun observe(raw: Any?, result: MethodChannel.Result) {
        triggerColdRecovery()
        val request = parse(result) { RdpFileTransferContract.lifecycle(raw) } ?: return
        val identity = exactIdentity(request, result) ?: return
        if (!ensureProcessOwnership()) {
            result.success(receipt(request.requestId, identity, "unknown"))
            return
        }
        val record = try {
            journal.read(identity)
        } catch (_: Exception) {
            result.success(receipt(request.requestId, identity, "unknown"))
            return
        }
        val needsReadback = hasUnresolvedProviderEffect(record)
        if (needsReadback) synchronized(lock) {
            if (currentIdentity == identity) stickyUnknown = true
        }
        if (needsReadback || synchronized(lock) { stickyUnknown }) {
            if (!foreground()) return error(result, "foregroundRequired")
            val grant = resolve(
                request.authority,
                request.grantId,
                request.grantRevision,
                result,
            ) ?: return
            when {
                needsReadback -> recoverUnknown(request, identity, grant, result)
                record.phase in setOf(
                    RdpSafTransferPhase.COMPLETE,
                    RdpSafTransferPhase.DISCARD_INTENT,
                ) ->
                    cleanupRecoveredComplete(request, identity, grant, result)
                record.phase == RdpSafTransferPhase.DISCARDED -> {
                    if (clearUnknown(identity, request.authority, grant)) {
                        result.success(receipt(request.requestId, identity, "saved"))
                    } else {
                        error(result, "staleSession")
                    }
                }
                record.phase == RdpSafTransferPhase.SEALED -> {
                    if (clearUnknown(identity, request.authority, grant)) {
                        result.success(receipt(request.requestId, identity, "sealed"))
                    } else {
                        error(result, "staleSession")
                    }
                }
                record.phase == RdpSafTransferPhase.UNKNOWN ->
                    recoverUnknown(request, identity, grant, result)
                else -> result.success(receipt(request.requestId, identity, "unknown"))
            }
            return
        }
        if (record.phase in setOf(
                RdpSafTransferPhase.COMPLETE,
                RdpSafTransferPhase.DISCARD_INTENT,
            )
        ) {
            if (!foreground()) return error(result, "foregroundRequired")
            val grant = resolve(
                request.authority,
                request.grantId,
                request.grantRevision,
                result,
            ) ?: return
            cleanupRecoveredComplete(request, identity, grant, result)
            return
        }
        val state = when (record.phase) {
                RdpSafTransferPhase.SESSION_ACTIVE -> synchronized(lock) {
                    if (openedSession?.fileTransferEndpoint?.transferId == identity.transferId) {
                        "active"
                    } else {
                        "prepared"
                    }
                }
                RdpSafTransferPhase.SEALED -> "sealed"
                RdpSafTransferPhase.DISCARDED -> "saved"
                else -> "unknown"
            }
        result.success(receipt(request.requestId, identity, state))
    }

    /**
     * The UNKNOWN recovery path performs provider readback only. The manager cannot create or write
     * provider documents from this entry point. Only the same still-active authority/grant may
     * publish a recovered state; zero/multiple candidates stay UNKNOWN and keep successors fenced.
     */
    private fun recoverUnknown(
        request: RdpFileTransferRequest,
        identity: RdpSafTransferIdentity,
        grant: RdpSafActiveGrant,
        result: MethodChannel.Result,
    ) {
        manager.recoverDispatchedSave(identity, grant) { outcome ->
            main.post {
                if (!foreground() || !recoveryOwnerCurrent(identity, request.authority, grant)) {
                    error(result, "staleSession")
                    return@post
                }
                when (outcome) {
                    is RdpSafMirrorResult.Saved ->
                        cleanupRecoveredComplete(request, identity, grant, result)
                    is RdpSafMirrorResult.Sealed -> {
                        if (clearUnknown(identity, request.authority, grant)) {
                            result.success(receipt(request.requestId, identity, "sealed"))
                        } else {
                            error(result, "staleSession")
                        }
                    }
                    RdpSafMirrorResult.Unknown ->
                        result.success(receipt(request.requestId, identity, "unknown"))
                    is RdpSafMirrorResult.Failure ->
                        error(result, failureCode(outcome.code))
                    else -> result.success(receipt(request.requestId, identity, "unknown"))
                }
            }
        }
    }

    private fun cleanupRecoveredComplete(
        request: RdpFileTransferRequest,
        identity: RdpSafTransferIdentity,
        grant: RdpSafActiveGrant,
        result: MethodChannel.Result,
    ) {
        val reserved = synchronized(lock) {
            if (disposed || !ownsProcess || currentIdentity != identity) return@synchronized false
            stickyUnknown = true
            true
        }
        if (!reserved) return error(result, "staleSession")
        manager.cleanupAfterSave(identity) { cleanup ->
            main.post {
                if (!foreground() || !recoveryOwnerCurrent(identity, request.authority, grant)) {
                    error(result, "staleSession")
                    return@post
                }
                if (cleanup is RdpSafMirrorResult.Saved) {
                    val published = synchronized(lock) {
                        if (currentIdentity == identity) {
                            currentMirrorRoot = null
                            stickyUnknown = false
                            true
                        } else {
                            false
                        }
                    }
                    if (published) {
                        result.success(receipt(request.requestId, identity, "saved"))
                    } else {
                        error(result, "staleSession")
                    }
                } else {
                    markUnknown(identity)
                    result.success(receipt(request.requestId, identity, "unknown"))
                }
            }
        }
    }

    fun drain(raw: Any?, result: MethodChannel.Result) {
        triggerColdRecovery()
        val request = parse(result) { RdpFileTransferContract.lifecycle(raw) } ?: return
        if (!ensureProcessOwnership()) return error(result, "busy")
        if (!foreground()) return error(result, "foregroundRequired")
        val identity = exactIdentity(request, result) ?: return
        if (synchronized(lock) { stickyUnknown }) {
            result.success(receipt(request.requestId, identity, "unknown"))
            return
        }
        synchronized(lock) {
            if (disposed || drainingIdentity != null ||
                openedSession?.fileTransferEndpoint?.transferId != identity.transferId
            ) return error(result, "busy")
            drainingIdentity = identity
        }
        manager.closeAndSeal(identity) { outcome ->
            main.post {
                synchronized(lock) { if (drainingIdentity == identity) drainingIdentity = null }
                when (outcome) {
                    is RdpSafMirrorResult.Sealed ->
                        result.success(receipt(request.requestId, identity, "sealed"))
                    RdpSafMirrorResult.Unknown -> {
                        markUnknown(identity)
                        result.success(receipt(request.requestId, identity, "unknown"))
                    }
                    is RdpSafMirrorResult.Failure -> error(result, failureCode(outcome.code))
                    else -> error(result, "connectionFailed")
                }
            }
        }
    }

    fun save(raw: Any?, result: MethodChannel.Result) {
        triggerColdRecovery()
        val request = parse(result) { RdpFileTransferContract.lifecycle(raw) } ?: return
        if (!ensureProcessOwnership()) return error(result, "busy")
        if (!foreground()) return error(result, "foregroundRequired")
        val identity = exactIdentity(request, result) ?: return
        if (synchronized(lock) { stickyUnknown }) {
            result.success(receipt(request.requestId, identity, "unknown"))
            return
        }
        val phase = runCatching { journal.read(identity).phase }.getOrNull()
        if (phase == RdpSafTransferPhase.DISCARDED) {
            result.success(receipt(request.requestId, identity, "saved"))
            return
        }
        if (phase in setOf(
                RdpSafTransferPhase.COMPLETE,
                RdpSafTransferPhase.DISCARD_INTENT,
            )
        ) {
            cleanupSaved(request, identity, result)
            return
        }
        val grant = resolve(request.authority, request.grantId, request.grantRevision, result) ?: return
        manager.saveReceived(identity, grant) { outcome ->
            main.post {
                if (disposed || !foreground()) {
                    markUnknown(identity)
                    return@post result.success(receipt(request.requestId, identity, "unknown"))
                }
                when (outcome) {
                    is RdpSafMirrorResult.Saved -> cleanupSaved(request, identity, result)
                    RdpSafMirrorResult.Unknown -> {
                        markUnknown(identity)
                        result.success(receipt(request.requestId, identity, "unknown"))
                    }
                    is RdpSafMirrorResult.Failure -> error(result, failureCode(outcome.code))
                    else -> error(result, "connectionFailed")
                }
            }
        }
    }

    private fun cleanupSaved(
        request: RdpFileTransferRequest,
        identity: RdpSafTransferIdentity,
        result: MethodChannel.Result,
    ) {
        manager.cleanupAfterSave(identity) { cleanup ->
            main.post {
                when (cleanup) {
                    is RdpSafMirrorResult.Saved -> {
                        synchronized(lock) {
                            if (currentIdentity == identity) currentMirrorRoot = null
                        }
                        result.success(receipt(request.requestId, identity, "saved"))
                    }
                    else -> {
                        markUnknown(identity)
                        result.success(receipt(request.requestId, identity, "unknown"))
                    }
                }
            }
        }
    }

    /** Claims a prepared private endpoint for this exact planned session. */
    fun endpointForOpen(request: RdpNativeRequest): RdpNativeFileTransferEndpoint? = synchronized(lock) {
        if (!request.files) return@synchronized null
        val identity = currentIdentity ?: throw RdpNativeFailure("channelUnavailable")
        val root = currentMirrorRoot ?: throw RdpNativeFailure("channelUnavailable")
        if (disposed || !ownsProcess || stickyUnknown || drainingIdentity != null || openedSession != null ||
            identity.sessionRequestId != request.requestId ||
            identity.sessionRevision != request.sessionRevision ||
            identity.transferId != request.fileTransferId ||
            journal.read(identity).phase != RdpSafTransferPhase.SESSION_ACTIVE
        ) throw RdpNativeFailure("staleSession")
        RdpNativeFileTransferEndpoint(
            identity.transferId,
            identity.sessionRequestId,
            identity.sessionRevision,
            root,
        )
    }

    fun sessionOpened(session: RdpNativeSession) {
        val endpoint = session.fileTransferEndpoint ?: return
        synchronized(lock) {
            val identity = currentIdentity
            if (disposed || stickyUnknown || identity == null ||
                endpoint.transferId != identity.transferId ||
                endpoint.sessionRequestId != identity.sessionRequestId ||
                endpoint.sessionRevision != identity.sessionRevision ||
                openedSession != null
            ) {
                session.close()
                throw RdpNativeFailure("staleSession")
            }
            openedSession = session
        }
    }

    /** A native close callback belongs to an already-reserved explicit drain, or makes it unknown. */
    fun nativeClosed(session: RdpNativeSession) {
        val endpoint = session.fileTransferEndpoint ?: return
        val exactDrain = synchronized(lock) {
            openedSession === session && drainingIdentity?.transferId == endpoint.transferId
        }
        if (!exactDrain) transportRetiring(session)
    }

    /** Generic cancel/retire is never a seal observation, including while drain is pending. */
    fun transportRetiring(session: RdpNativeSession) {
        val endpoint = session.fileTransferEndpoint ?: return
        val identity = synchronized(lock) {
            if (openedSession !== session) return
            currentIdentity?.takeIf { it.transferId == endpoint.transferId }
        } ?: return
        // Retain the exact session until coordinator close proves native drain. RdpNativeBridge
        // retires the transport before disposing this coordinator; dropping the reference here
        // would otherwise let dispose release the process owner while native writers still run.
        markUnknown(identity, retainSession = session)
    }

    fun openFailed(endpoint: RdpNativeFileTransferEndpoint?) {
        if (endpoint == null) return
        val identity = synchronized(lock) {
            currentIdentity?.takeIf {
                it.transferId == endpoint.transferId &&
                    it.sessionRequestId == endpoint.sessionRequestId &&
                    it.sessionRevision == endpoint.sessionRevision
            }
        } ?: return
        markUnknown(identity)
    }

    private fun drainExactSession(
        identity: RdpSafTransferIdentity,
        callback: (Result<RdpSafNativeCloseReceipt>) -> Unit,
    ) {
        val owned = synchronized(lock) {
            openedSession?.takeIf {
                currentIdentity == identity && drainingIdentity == identity &&
                    it.fileTransferEndpoint?.transferId == identity.transferId
            }
        }
        if (owned == null) {
            callback(Result.failure(IllegalStateException("stale_transfer_session")))
            return
        }
        val drained = owned.closeAndAwaitNativeDrain()
        clearSession(owned)
        synchronized(lock) { if (openedSession === owned) openedSession = null }
        if (!drained) {
            callback(Result.failure(IllegalStateException("native_drain_unknown")))
            return
        }
        val receiptId = randomHex().also(::requireHex32)
        callback(Result.success(RdpSafNativeCloseReceipt(
            identity.transferId,
            identity.sessionRequestId,
            identity.sessionRevision,
            receiptId,
            nativeWritersClosed = true,
        )))
    }

    private fun exactIdentity(
        request: RdpFileTransferRequest,
        result: MethodChannel.Result,
    ): RdpSafTransferIdentity? {
        val identity = synchronized(lock) { currentIdentity }
        if (identity == null || identity.transferId != request.transferId ||
            identity.authorityId != request.authority.authorityId ||
            identity.grantId != request.grantId || identity.grantRevision != request.grantRevision ||
            identity.sessionRequestId != request.sessionRequestId ||
            identity.sessionRevision != request.sessionRevision
        ) {
            error(result, "staleSession")
            return null
        }
        return identity
    }

    private fun resolve(
        authority: RdpSafAuthority,
        grantId: String,
        grantRevision: Long,
        result: MethodChannel.Result,
    ): RdpSafActiveGrant? = try {
        grantResolver(authority, grantId, grantRevision)
    } catch (failure: RdpSafFailure) {
        error(result, failureCode(failure.code))
        null
    } catch (_: Exception) {
        error(result, "engineUnavailable")
        null
    }

    private fun recoveryOwnerCurrent(
        identity: RdpSafTransferIdentity,
        authority: RdpSafAuthority,
        expectedGrant: RdpSafActiveGrant,
    ): Boolean {
        val exact = synchronized(lock) {
            !disposed && ownsProcess && currentIdentity == identity
        }
        if (!exact) return false
        val current = runCatching {
            grantResolver(authority, identity.grantId, identity.grantRevision)
        }.getOrNull()
        return current == expectedGrant
    }

    private fun clearUnknown(
        identity: RdpSafTransferIdentity,
        authority: RdpSafAuthority,
        expectedGrant: RdpSafActiveGrant,
    ): Boolean {
        if (!recoveryOwnerCurrent(identity, authority, expectedGrant)) return false
        return synchronized(lock) {
            if (disposed || currentIdentity != identity || !stickyUnknown) return@synchronized false
            stickyUnknown = false
            true
        }
    }

    private fun terminal(identity: RdpSafTransferIdentity): Boolean = try {
        // COMPLETE is cleanup debt. A successor may replace the durable journal only after the
        // exact private mirror has been removed and DISCARDED is durable.
        journal.read(identity).phase == RdpSafTransferPhase.DISCARDED
    } catch (_: Exception) {
        false
    }

    private fun requiresReadbackRecovery(record: RdpSafTransferRecord): Boolean =
        record.phase in setOf(
            RdpSafTransferPhase.UNKNOWN,
            RdpSafTransferPhase.COMPLETE,
            RdpSafTransferPhase.DISCARD_INTENT,
        ) ||
            hasUnresolvedProviderEffect(record)

    private fun hasUnresolvedProviderEffect(record: RdpSafTransferRecord): Boolean =
        record.fromRemote.any {
            it.phase in setOf(
                RdpSafFileCommitPhase.SAF_CREATE_DISPATCHED,
                RdpSafFileCommitPhase.SAF_CREATED,
                RdpSafFileCommitPhase.SAF_WRITE_DISPATCHED,
                RdpSafFileCommitPhase.UNKNOWN,
            )
        }

    private fun markUnknown(
        identity: RdpSafTransferIdentity,
        retainSession: RdpNativeSession? = null,
    ) {
        synchronized(lock) {
            if (currentIdentity != identity) return
            stickyUnknown = true
            if (retainSession == null || openedSession !== retainSession) openedSession = null
        }
        runCatching { journal.markUnknown(identity) }
    }

    /**
     * Process restart loses Dart's transfer tuple. Recover the exact encrypted native journal and
     * active grant without replaying provider writes. Only a fully verified saved effect is cleaned
     * automatically; sealed or ambiguous work remains fenced for explicit user reconciliation.
     */
    private fun ensureProcessOwnership(): Boolean {
        if (synchronized(lock) { ownsProcess }) return true
        if (!processOwner.tryAcquire(processOwnerToken)) return false
        val snapshot = runCatching { journal.snapshot() }
        val priorProcess = snapshot.getOrNull()?.identity?.processEpoch != null &&
            snapshot.getOrNull()?.identity?.processEpoch != processEpoch
        val refreshed = runCatching { journal.recover(processEpoch) }
        synchronized(lock) {
            if (disposed) {
                processOwner.release(processOwnerToken)
                return false
            }
            ownsProcess = true
            coldReadbackAllowed = priorProcess
            recovered = refreshed.getOrNull()
            currentIdentity = recovered?.identity
            currentMirrorRoot = recovered?.mirrorRoot
            openedSession = null
            drainingIdentity = null
            stickyUnknown = refreshed.isFailure ||
                recovered?.let(::requiresReadbackRecovery) == true
        }
        return true
    }

    private fun attemptColdRecovery() {
        if (!ensureProcessOwnership()) {
            if (SystemClock.elapsedRealtime() < coldRecoveryDeadline) {
                scheduleColdRecovery(COLD_RECOVERY_RETRY_MS)
            }
            return
        }
        val identity = synchronized(lock) {
            if (disposed || !stickyUnknown || !coldReadbackAllowed || coldRecoveryInFlight) return
            currentIdentity
        } ?: return
        if (!foreground()) {
            if (SystemClock.elapsedRealtime() < coldRecoveryDeadline) {
                scheduleColdRecovery(COLD_RECOVERY_RETRY_MS)
            }
            return
        }
        val grant = runCatching { coldGrantResolver(identity) }.getOrNull() ?: return
        synchronized(lock) {
            if (disposed || !stickyUnknown || currentIdentity != identity) return
            coldRecoveryInFlight = true
        }
        val record = runCatching { journal.read(identity) }.getOrNull()
        if (record == null) {
            synchronized(lock) { coldRecoveryInFlight = false }
            return
        }
        if (record.phase in setOf(
                RdpSafTransferPhase.COMPLETE,
                RdpSafTransferPhase.DISCARD_INTENT,
            )
        ) {
            manager.cleanupAfterSave(identity) { cleanup ->
                main.post {
                    synchronized(lock) { coldRecoveryInFlight = false }
                    if (cleanup !is RdpSafMirrorResult.Saved ||
                        !coldRecoveryOwnerCurrent(identity, grant)
                    ) return@post
                    synchronized(lock) {
                        if (!disposed && stickyUnknown && currentIdentity == identity) {
                            stickyUnknown = false
                            currentMirrorRoot = null
                        }
                    }
                }
            }
            return
        }
        manager.recoverDispatchedSave(identity, grant) { outcome ->
            main.post {
                synchronized(lock) { coldRecoveryInFlight = false }
                if (!coldRecoveryOwnerCurrent(identity, grant)) return@post
                if (outcome !is RdpSafMirrorResult.Saved) return@post
                manager.cleanupAfterSave(identity) { cleanup ->
                    main.post {
                        if (cleanup !is RdpSafMirrorResult.Saved ||
                            !coldRecoveryOwnerCurrent(identity, grant)
                        ) return@post
                        synchronized(lock) {
                            if (!disposed && stickyUnknown && currentIdentity == identity) {
                                stickyUnknown = false
                                currentMirrorRoot = null
                            }
                        }
                    }
                }
            }
        }
    }

    private fun triggerColdRecovery() {
        if (synchronized(lock) { !disposed && stickyUnknown }) scheduleColdRecovery(0)
    }

    private fun scheduleColdRecovery(delayMs: Long) {
        val scheduled = synchronized(lock) {
            if (disposed || !stickyUnknown || coldRecoveryScheduled) return
            coldRecoveryScheduled = true
            true
        }
        if (scheduled && !main.postDelayed(coldRecovery, delayMs)) {
            synchronized(lock) { coldRecoveryScheduled = false }
        }
    }

    private fun coldRecoveryOwnerCurrent(
        identity: RdpSafTransferIdentity,
        expectedGrant: RdpSafActiveGrant,
    ): Boolean {
        if (!foreground() || synchronized(lock) {
                disposed || !stickyUnknown || currentIdentity != identity
            }
        ) return false
        return runCatching { coldGrantResolver(identity) }.getOrNull() == expectedGrant
    }

    private fun receipt(requestId: String, identity: RdpSafTransferIdentity, state: String) =
        RdpFileTransferContract.receipt(
            requestId,
            identity.authorityId,
            identity.grantId,
            identity.grantRevision,
            identity.transferId,
            state,
        )

    private fun failureCode(code: String): String = when (code) {
        "busy" -> "busy"
        "authority_changed" -> "staleSession"
        "invalid_request" -> "invalidRequest"
        else -> "engineUnavailable"
    }

    private fun <T> parse(result: MethodChannel.Result, block: () -> T): T? = try {
        block()
    } catch (failure: RdpNativeFailure) {
        error(result, failure.code)
        null
    } catch (_: Exception) {
        error(result, "invalidRequest")
        null
    }

    private fun error(result: MethodChannel.Result, code: String) {
        val safe = if (code in ERROR_CODES) code else "connectionFailed"
        result.error(safe, "RDP file transfer unavailable", null)
    }

    override fun close() {
        val owned = synchronized(lock) {
            if (disposed) return
            disposed = true
            openedSession.also { openedSession = null }
        }
        main.removeCallbacks(coldRecovery)
        synchronized(lock) { coldRecoveryScheduled = false }

        // MainActivity disposes bridges on the Android main thread. Native drain can wait for the
        // package cleanup worker, so perform the complete proof on an owned daemon thread. The
        // process reservation is released only when both proofs finish inside one monotonic bound;
        // a late true result is cleanup evidence only and can never admit a successor.
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(processOwnerCloseWaitMs)
        Thread({
            val nativeDrained = owned?.let {
                try {
                    it.closeAndAwaitNativeDrain()
                } catch (_: Exception) {
                    false
                } finally {
                    clearSession(it)
                }
            } ?: true
            val remainingNanos = (deadline - System.nanoTime()).coerceAtLeast(0)
            val remainingMs = if (remainingNanos == 0L) 0L else {
                TimeUnit.NANOSECONDS.toMillis(remainingNanos).coerceAtLeast(1L)
            }
            val managerQuiesced = manager.closeAndAwaitQuiescence(remainingMs)
            val timely = System.nanoTime() <= deadline
            val release = synchronized(lock) {
                if (ownsProcess && nativeDrained && managerQuiesced && timely) {
                    ownsProcess = false
                    true
                } else {
                    false
                }
            }
            if (release) processOwner.release(processOwnerToken)
        }, "larenor-rdp-saf-close").apply { isDaemon = true }.start()
    }

    companion object {
        private const val MIRROR_DIRECTORY = "rdp-saf-mirrors-v1"
        private const val COLD_RECOVERY_WINDOW_MS = 30_000L
        private const val COLD_RECOVERY_RETRY_MS = 250L
        private const val PROCESS_OWNER_CLOSE_WAIT_MS = 250L
        private const val MAX_PROCESS_OWNER_CLOSE_WAIT_MS = 10_000L
        private val ERROR_CODES = setOf(
            "invalidRequest", "staleSession", "foregroundRequired", "busy",
            "engineUnavailable", "connectionFailed",
        )

        private fun requireHex32(value: String) {
            require(RdpSafContract.HEX_32.matches(value))
        }
    }
}
