package com.ersingundem.larenor.rdp

import android.net.Uri
import android.os.CancellationSignal
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@org.junit.runner.RunWith(org.robolectric.RobolectricTestRunner::class)
@org.robolectric.annotation.Config(sdk = [35], manifest = org.robolectric.annotation.Config.NONE)
class RdpSafMirrorManagerTest {
    private class Store : RdpSafTransferStore {
        @Volatile var value: RdpSafTransferRecord? = null
        @Volatile var rejectUnknownWrites = false
        @Synchronized override fun read() = value
        @Synchronized override fun replace(value: RdpSafTransferRecord) {
            if (rejectUnknownWrites && value.phase == RdpSafTransferPhase.UNKNOWN) {
                error("owned unknown persistence failure")
            }
            this.value = value
        }
        @Synchronized override fun clear(expectedTransferId: String) { value = null }
    }

    private class Documents : RdpSafDocumentsPort {
        var creates = 0
        var writes = 0
        var readbacks = 0
        var blockCreate: CountDownLatch? = null
        private val provider = RdpSafDocument(
            Uri.parse("content://owned/document/1"),
            "larenor-download.bin",
            "application/octet-stream",
            72,
            0,
        )

        override fun snapshotToRemote(
            treeUri: Uri,
            targetDirectory: File,
            cancel: CancellationSignal,
        ): List<RdpSafSealedFile> = emptyList()

        override fun inspectSaveCandidate(
            treeUri: Uri,
            name: String,
            cancel: CancellationSignal,
        ): RdpSafCandidateSet = RdpSafCandidateSet.None

        override fun createForSave(
            treeUri: Uri,
            name: String,
            cancel: CancellationSignal,
        ): RdpSafDocument {
            creates++
            blockCreate?.await(5, TimeUnit.SECONDS)
            return provider.copy(name = name)
        }

        override fun writeOnce(
            document: RdpSafDocument,
            source: RdpSafSealedFile,
            cancel: CancellationSignal,
        ) { writes++ }

        override fun readback(
            document: RdpSafDocument,
            expected: RdpSafSealedFile,
            cancel: CancellationSignal,
        ): Boolean { readbacks++; return true }
    }

    private class Drain : RdpSafNativeDrain {
        lateinit var callback: (Result<RdpSafNativeCloseReceipt>) -> Unit
        override fun close(
            identity: RdpSafTransferIdentity,
            callback: (Result<RdpSafNativeCloseReceipt>) -> Unit,
        ) { this.callback = callback }
        fun ready() = this::callback.isInitialized
    }

    private class CallbackThenThrowDrain(
        private val receipt: RdpSafNativeCloseReceipt,
    ) : RdpSafNativeDrain {
        override fun close(
            identity: RdpSafTransferIdentity,
            callback: (Result<RdpSafNativeCloseReceipt>) -> Unit,
        ) {
            callback(Result.success(receipt))
            error("native close failed after callback")
        }
    }

    @Test
    fun confirmedNativeCloseSealsWithoutPublishingAndExplicitSavePublishesOnce() {
        val root = Files.createTempDirectory("saf-stage2-manager").toFile()
        val store = Store()
        val documents = Documents()
        val drain = Drain()
        val journal = RdpSafTransferJournal(store)
        val manager = RdpSafMirrorManager(root, journal, documents, drain, EPOCH)
        val prepared = await { manager.prepare(identity(), grant(), it) } as RdpSafMirrorResult.Prepared
        File(prepared.mirrorRoot, RdpSafDocumentsAdapter.FROM_REMOTE).resolve("larenor-download.bin")
            .writeBytes(ByteArray(72) { 7 })

        val closeLatch = CountDownLatch(1)
        var closeResult: RdpSafMirrorResult? = null
        manager.closeAndSeal(identity()) { closeResult = it; closeLatch.countDown() }
        waitUntil { drain.ready() }
        assertEquals(0, documents.creates)
        assertEquals(0, documents.writes)
        drain.callback(Result.success(closeReceipt()))
        assertTrue(closeLatch.await(2, TimeUnit.SECONDS))
        assertTrue(closeResult is RdpSafMirrorResult.Sealed)
        assertEquals(0, documents.creates)
        assertEquals(0, documents.writes)

        val saved = await { manager.saveReceived(identity(), grant(), it) }

        assertTrue(saved is RdpSafMirrorResult.Saved)
        assertEquals(1, documents.creates)
        assertEquals(1, documents.writes)
        assertEquals(1, documents.readbacks)
        assertEquals(RdpSafTransferPhase.COMPLETE, store.value?.phase)
        manager.close()
    }

    @Test
    fun providerCreateDeadlineLeavesUnknownAndNeverWritesOrRetries() {
        val root = Files.createTempDirectory("saf-stage2-timeout").toFile()
        val store = Store()
        val documents = Documents().apply { blockCreate = CountDownLatch(1) }
        val journal = RdpSafTransferJournal(store)
        val manager = RdpSafMirrorManager(
            root,
            journal,
            documents,
            Drain(),
            EPOCH,
            operationTimeoutMs = 25,
        )
        seedSealed(root, journal)

        val result = await { manager.saveReceived(identity(), grant(), it) }

        assertTrue(result is RdpSafMirrorResult.Unknown)
        assertEquals(1, documents.creates)
        assertEquals(0, documents.writes)
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)
        documents.blockCreate?.countDown()
        Thread.sleep(30)
        assertEquals(1, documents.creates)
        assertEquals(0, documents.writes)
        manager.close()
    }

    @Test
    fun failedUnknownPersistenceAndLateWorkerCompletionPublishExactlyOnceAndStayBusy() {
        val root = Files.createTempDirectory("saf-stage2-unknown-write-failure").toFile()
        val store = Store()
        val createGate = CountDownLatch(1)
        val documents = Documents().apply { blockCreate = createGate }
        val journal = RdpSafTransferJournal(store)
        val manager = RdpSafMirrorManager(
            root,
            journal,
            documents,
            Drain(),
            EPOCH,
            operationTimeoutMs = 25,
        )
        seedSealed(root, journal)
        store.rejectUnknownWrites = true
        val resultLatch = CountDownLatch(1)
        val callbackCount = AtomicInteger()
        var result: RdpSafMirrorResult? = null

        manager.saveReceived(identity(), grant()) {
            result = it
            callbackCount.incrementAndGet()
            resultLatch.countDown()
        }

        waitUntil { documents.creates == 1 }
        assertTrue(resultLatch.await(2, TimeUnit.SECONDS))
        assertTrue(result is RdpSafMirrorResult.Unknown)
        assertEquals(1, callbackCount.get())
        val successor = identity().copy(
            transferId = "9".repeat(32),
            sessionRequestId = "22222222-2222-4222-8222-222222222222",
            sessionRevision = 2,
        )
        assertEquals(
            RdpSafMirrorResult.Failure("busy"),
            await { manager.prepare(successor, grant(), it) },
        )

        createGate.countDown()
        Thread.sleep(75)
        assertEquals(1, callbackCount.get())
        assertFalse(manager.closeAndAwaitQuiescence(1_000))
    }

    @Test
    fun staleOrWrongNativeCloseReceiptCannotSealOrPublish() {
        val root = Files.createTempDirectory("saf-stage2-close").toFile()
        val store = Store()
        val documents = Documents()
        val drain = Drain()
        val journal = RdpSafTransferJournal(store)
        val manager = RdpSafMirrorManager(root, journal, documents, drain, EPOCH)
        await { manager.prepare(identity(), grant(), it) }
        val resultLatch = CountDownLatch(1)
        var result: RdpSafMirrorResult? = null
        manager.closeAndSeal(identity()) { result = it; resultLatch.countDown() }
        waitUntil { drain.ready() }

        drain.callback(Result.success(closeReceipt().copy(sessionRevision = 2)))

        assertTrue(resultLatch.await(2, TimeUnit.SECONDS))
        assertTrue(result is RdpSafMirrorResult.Unknown)
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)
        assertEquals(0, documents.creates)
        assertEquals(0, documents.writes)
        manager.close()
    }

    @Test
    fun overlappingSaveIsRejectedWithoutCancelingOrRebindingTheOwnedEffect() {
        val root = Files.createTempDirectory("saf-stage2-overlap").toFile()
        val store = Store()
        val createGate = CountDownLatch(1)
        val documents = Documents().apply { blockCreate = createGate }
        val journal = RdpSafTransferJournal(store)
        val manager = RdpSafMirrorManager(root, journal, documents, Drain(), EPOCH)
        seedSealed(root, journal)
        val firstLatch = CountDownLatch(1)
        var first: RdpSafMirrorResult? = null
        manager.saveReceived(identity(), grant()) { first = it; firstLatch.countDown() }
        waitUntil { documents.creates == 1 }

        val overlap = await { manager.saveReceived(identity(), grant(), it) }

        assertEquals(RdpSafMirrorResult.Failure("busy"), overlap)
        assertEquals(1, documents.creates)
        assertEquals(0, documents.writes)
        createGate.countDown()
        assertTrue(firstLatch.await(2, TimeUnit.SECONDS))
        assertTrue(first is RdpSafMirrorResult.Saved)
        assertEquals(1, documents.writes)
        manager.close()
    }

    @Test
    fun explicitEmptySaveDurablyCompletesAndReplaysWithoutProviderEffects() {
        val root = Files.createTempDirectory("saf-stage2-empty").toFile()
        val store = Store()
        val documents = Documents()
        val drain = Drain()
        val journal = RdpSafTransferJournal(store)
        val manager = RdpSafMirrorManager(root, journal, documents, drain, EPOCH)
        await { manager.prepare(identity(), grant(), it) }
        val closeLatch = CountDownLatch(1)
        manager.closeAndSeal(identity()) { closeLatch.countDown() }
        waitUntil { drain.ready() }
        drain.callback(Result.success(closeReceipt()))
        assertTrue(closeLatch.await(2, TimeUnit.SECONDS))

        val first = await { manager.saveReceived(identity(), grant(), it) }
        val replay = await { manager.saveReceived(identity(), grant(), it) }

        assertEquals(RdpSafMirrorResult.Saved(identity().transferId, 0), first)
        assertEquals(first, replay)
        assertEquals(RdpSafTransferPhase.COMPLETE, store.value?.phase)
        assertEquals(0, documents.creates)
        assertEquals(0, documents.writes)
        manager.close()
    }

    @Test
    fun durableUnknownRejectsFreshPrepareBeforeCreatingMirrorDirectory() {
        val root = Files.createTempDirectory("saf-stage2-unknown").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val oldDrive = File(root, "old/root").apply { mkdirs() }
        journal.create(identity(), oldDrive)
        journal.markUnknown(identity())
        val manager = RdpSafMirrorManager(root, journal, Documents(), Drain(), EPOCH)
        val successor = identity().copy(
            transferId = "9".repeat(32),
            sessionRequestId = "22222222-2222-4222-8222-222222222222",
            sessionRevision = 2,
        )

        val result = await { manager.prepare(successor, grant(), it) }

        assertTrue(result is RdpSafMirrorResult.Unknown)
        assertTrue(!File(root, successor.transferId).exists())
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)
        manager.close()
    }

    @Test
    fun sealingDeadlinePersistsUnknownAndLateSealerCannotUpgrade() {
        val root = Files.createTempDirectory("saf-stage2-seal-deadline").toFile()
        val store = Store()
        val drain = Drain()
        val sealStarted = CountDownLatch(1)
        val releaseSeal = CountDownLatch(1)
        val journal = RdpSafTransferJournal(store)
        val manager = RdpSafMirrorManager(
            root,
            journal,
            Documents(),
            drain,
            EPOCH,
            operationTimeoutMs = 25,
            sealOverride = { _, _ ->
                sealStarted.countDown()
                releaseSeal.await(5, TimeUnit.SECONDS)
                emptyList()
            },
        )
        await { manager.prepare(identity(), grant(), it) }
        val resultLatch = CountDownLatch(1)
        var callbackCount = 0
        var result: RdpSafMirrorResult? = null
        manager.closeAndSeal(identity()) {
            callbackCount++
            result = it
            resultLatch.countDown()
        }
        waitUntil { drain.ready() }
        drain.callback(Result.success(closeReceipt()))
        assertTrue(sealStarted.await(2, TimeUnit.SECONDS))
        assertTrue(resultLatch.await(2, TimeUnit.SECONDS))
        assertTrue(result is RdpSafMirrorResult.Unknown)
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)

        releaseSeal.countDown()
        Thread.sleep(50)
        assertEquals(1, callbackCount)
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)
        manager.close()
    }

    @Test
    fun pendingNativeCloseCallbackPreventsQuiescentManagerClose() {
        val root = Files.createTempDirectory("saf-stage2-pending-native-close").toFile()
        val store = Store()
        val drain = Drain()
        val journal = RdpSafTransferJournal(store)
        val executor = Executors.newSingleThreadExecutor()
        val deadlines = Executors.newSingleThreadScheduledExecutor()
        val manager = RdpSafMirrorManager(
            root,
            journal,
            Documents(),
            drain,
            EPOCH,
            executor = executor,
            deadlines = deadlines,
        )
        await { manager.prepare(identity(), grant(), it) }
        manager.closeAndSeal(identity()) { error("disposed close must not publish") }
        waitUntil { drain.ready() }

        assertFalse(manager.closeAndAwaitQuiescence(25))
        assertTrue(executor.isShutdown)
        assertTrue(deadlines.isShutdown)
        drain.callback(Result.success(closeReceipt()))
        waitUntil { executor.isTerminated && deadlines.isTerminated }
        assertFalse(manager.closeAndAwaitQuiescence(25))
    }

    @Test
    fun synchronousNativeCallbackThenThrowPublishesOnceAndCannotCorruptQuiescence() {
        val root = Files.createTempDirectory("saf-stage2-callback-throw").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val manager = RdpSafMirrorManager(
            root,
            journal,
            Documents(),
            CallbackThenThrowDrain(closeReceipt()),
            EPOCH,
        )
        await { manager.prepare(identity(), grant(), it) }
        val resultLatch = CountDownLatch(1)
        var callbackCount = 0
        var result: RdpSafMirrorResult? = null

        manager.closeAndSeal(identity()) {
            callbackCount++
            result = it
            resultLatch.countDown()
        }

        assertTrue(resultLatch.await(2, TimeUnit.SECONDS))
        assertEquals(1, callbackCount)
        assertTrue(result is RdpSafMirrorResult.Unknown)
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)
        assertTrue(manager.closeAndAwaitQuiescence(1_000))
    }

    private fun seedSealed(root: File, journal: RdpSafTransferJournal) {
        val drive = File(root, "${identity().transferId}/root").apply { mkdirs() }
        val received = File(drive, RdpSafDocumentsAdapter.FROM_REMOTE).apply { mkdirs() }
            .resolve("larenor-download.bin").apply { writeBytes(ByteArray(72) { 7 }) }
        journal.create(identity(), drive)
        journal.prepared(identity(), emptyList())
        journal.closeRequested(identity())
        journal.sealed(identity(), "f".repeat(32), listOf(received.sealed()))
    }

    private fun await(start: ((RdpSafMirrorResult) -> Unit) -> Unit): RdpSafMirrorResult {
        val latch = CountDownLatch(1)
        var result: RdpSafMirrorResult? = null
        start { result = it; latch.countDown() }
        assertTrue(latch.await(2, TimeUnit.SECONDS))
        return result!!
    }

    private fun waitUntil(condition: () -> Boolean) {
        repeat(100) {
            if (condition()) return
            Thread.sleep(5)
        }
        error("condition not reached")
    }

    private fun identity() = RdpSafTransferIdentity(
        "a".repeat(32), "b".repeat(64), "c".repeat(32), 1,
        "11111111-1111-4111-8111-111111111111", 1, EPOCH,
    )
    private fun grant() = RdpSafActiveGrant("b".repeat(64), "c".repeat(32), 1, Uri.parse("content://owned/tree"))
    private fun closeReceipt() = RdpSafNativeCloseReceipt(
        "a".repeat(32), "11111111-1111-4111-8111-111111111111", 1, "d".repeat(32), true,
    )
    private fun File.sealed() = RdpSafSealedFile(
        name, length(), java.security.MessageDigest.getInstance("SHA-256").digest(readBytes())
            .joinToString("") { "%02x".format(it) }, this,
    )

    companion object { private val EPOCH = "e".repeat(32) }
}
