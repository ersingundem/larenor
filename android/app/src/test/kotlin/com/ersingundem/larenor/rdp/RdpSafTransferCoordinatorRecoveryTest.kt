package com.ersingundem.larenor.rdp

import android.app.Activity
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
@LooperMode(LooperMode.Mode.PAUSED)
class RdpSafTransferCoordinatorRecoveryTest {
    private class Store : RdpSafTransferStore {
        var value: RdpSafTransferRecord? = null
        override fun read() = value
        override fun replace(value: RdpSafTransferRecord) { this.value = value }
        override fun clear(expectedTransferId: String) { value = null }
    }

    private class Documents(
        var candidate: RdpSafCandidateSet,
        private val blockWrite: Boolean = false,
    ) : RdpSafDocumentsPort {
        var creates = 0
        var writes = 0
        var readbacks = 0
        var inspections = 0
        val writeEntered = CountDownLatch(1)
        val releaseWrite = CountDownLatch(1)

        override fun snapshotToRemote(
            treeUri: Uri,
            targetDirectory: File,
            cancel: CancellationSignal,
        ) = emptyList<RdpSafSealedFile>()

        override fun inspectSaveCandidate(
            treeUri: Uri,
            name: String,
            cancel: CancellationSignal,
        ): RdpSafCandidateSet {
            inspections++
            return candidate
        }

        override fun createForSave(
            treeUri: Uri,
            name: String,
            cancel: CancellationSignal,
        ): RdpSafDocument {
            creates++
            if (blockWrite) return RdpSafDocument(
                DOCUMENT_URI,
                FILE_NAME,
                "application/octet-stream",
                72,
                0,
            )
            error("recovery must not create")
        }

        override fun writeOnce(
            document: RdpSafDocument,
            source: RdpSafSealedFile,
            cancel: CancellationSignal,
        ) {
            writes++
            if (!blockWrite) error("recovery must not write")
            writeEntered.countDown()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (releaseWrite.count != 0L && System.nanoTime() < deadline) {
                try {
                    releaseWrite.await(25, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    // Model a remote DocumentsProvider call that does not honor caller interruption.
                }
            }
        }

        override fun readback(
            document: RdpSafDocument,
            expected: RdpSafSealedFile,
            cancel: CancellationSignal,
        ): Boolean {
            readbacks++
            return true
        }
    }

    /** Models fchmod failure followed by an unsuccessful best-effort part deletion. */
    private class PermissionFailureDocuments : RdpSafDocumentsPort {
        lateinit var retainedPart: File
        var providerEffects = 0

        override fun snapshotToRemote(
            treeUri: Uri,
            targetDirectory: File,
            cancel: CancellationSignal,
        ): List<RdpSafSealedFile> {
            retainedPart = File(targetDirectory, ".permission-denied.part")
            check(retainedPart.createNewFile())
            throw SecurityException("permission denied")
        }

        override fun inspectSaveCandidate(
            treeUri: Uri,
            name: String,
            cancel: CancellationSignal,
        ): RdpSafCandidateSet {
            providerEffects++
            error("permission failure recovery must not inspect the provider")
        }

        override fun createForSave(
            treeUri: Uri,
            name: String,
            cancel: CancellationSignal,
        ): RdpSafDocument {
            providerEffects++
            error("permission failure recovery must not create a provider document")
        }

        override fun writeOnce(
            document: RdpSafDocument,
            source: RdpSafSealedFile,
            cancel: CancellationSignal,
        ) {
            providerEffects++
            error("permission failure recovery must not write a provider document")
        }

        override fun readback(
            document: RdpSafDocument,
            expected: RdpSafSealedFile,
            cancel: CancellationSignal,
        ): Boolean {
            providerEffects++
            error("permission failure recovery must not read back a provider document")
        }
    }

    private class MethodResult : MethodChannel.Result {
        private val done = CountDownLatch(1)
        var value: Any? = null
        var code: String? = null

        override fun success(result: Any?) {
            value = result
            done.countDown()
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            code = errorCode
            done.countDown()
        }

        override fun notImplemented() {
            code = "notImplemented"
            done.countDown()
        }

        fun await() {
            repeat(200) {
                shadowOf(Looper.getMainLooper()).idle()
                if (done.await(5, TimeUnit.MILLISECONDS)) return
            }
            error("result deadline")
        }
    }

    private class BlockingSession(
        override val fileTransferEndpoint: RdpNativeFileTransferEndpoint,
    ) : RdpNativeSession {
        val drainEntered = CountDownLatch(1)
        val releaseDrain = CountDownLatch(1)

        override fun closeAndAwaitNativeDrain(): Boolean {
            drainEntered.countDown()
            return releaseDrain.await(5, TimeUnit.SECONDS)
        }

        override fun close() = Unit
    }

    @Test
    fun coldRestartRecoversExactAckLossByReadbackOnlyAndUnblocksSuccessor() {
        val fixture = fixture(RdpSafCandidateSet.One(document()))

        awaitCondition { fixture.store.value?.phase == RdpSafTransferPhase.DISCARDED }
        assertEquals(0, fixture.documents.creates)
        assertEquals(0, fixture.documents.writes)
        assertEquals(1, fixture.documents.readbacks)

        val successor = MethodResult()
        fixture.coordinator.prepare(prepareRequest(SECOND_REQUEST_ID), successor)
        successor.await()
        assertEquals(null, successor.code)
        assertEquals("prepared", (successor.value as Map<*, *>)["state"])
        fixture.coordinator.close()
    }

    @Test
    fun coldRestartDetectsDispatchedWriteEvenBeforeTransferUnknownWasPersisted() {
        val fixture = fixture(
            RdpSafCandidateSet.One(document()),
            persistTransferUnknown = false,
        )

        awaitCondition { fixture.store.value?.phase == RdpSafTransferPhase.DISCARDED }
        assertEquals(1, fixture.documents.inspections)
        assertEquals(1, fixture.documents.readbacks)
        assertEquals(0, fixture.documents.creates)
        assertEquals(0, fixture.documents.writes)
        fixture.coordinator.close()
    }

    @Test
    fun ambiguousRestartObservationRemainsUnknownAndBlocksSuccessor() {
        val fixture = fixture(RdpSafCandidateSet.Multiple)
        awaitCondition { fixture.documents.inspections == 1 }
        assertEquals(RdpSafTransferPhase.UNKNOWN, fixture.store.value?.phase)
        assertEquals(0, fixture.documents.creates)
        assertEquals(0, fixture.documents.writes)
        assertEquals(0, fixture.documents.readbacks)

        val successor = MethodResult()
        fixture.coordinator.prepare(prepareRequest(SECOND_REQUEST_ID), successor)
        successor.await()
        assertEquals("busy", successor.code)
        fixture.coordinator.close()
    }

    @Test
    fun coldRestartWithoutExactActiveGrantPerformsNoProviderReadbackAndBlocksSuccessor() {
        val fixture = fixture(RdpSafCandidateSet.One(document()), coldGrantAvailable = false)

        awaitCondition { fixture.coldGrantResolutions.get() == 1 }
        assertEquals(0, fixture.documents.inspections)
        assertEquals(0, fixture.documents.readbacks)
        assertEquals(RdpSafTransferPhase.UNKNOWN, fixture.store.value?.phase)

        val successor = MethodResult()
        fixture.coordinator.prepare(prepareRequest(SECOND_REQUEST_ID), successor)
        successor.await()
        assertEquals("busy", successor.code)
        fixture.coordinator.close()
    }

    @Test
    fun privatePartPermissionFailureRetainsOwnedUnknownAcrossColdRestart() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = Files.createTempDirectory("saf-permission-owned-unknown").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val documents = PermissionFailureDocuments()
        val owner = RdpSafProcessOwner(NEW_EPOCH)
        val first = coordinator(
            activity,
            journal,
            manager(root, journal, documents, NEW_EPOCH),
            owner,
            { true },
        )

        val failed = MethodResult()
        first.prepare(prepareRequest(SESSION_REQUEST_ID), failed)
        failed.await()

        assertEquals("connectionFailed", failed.code)
        val retained = store.value!!
        assertEquals(RdpSafTransferPhase.UNKNOWN, retained.phase)
        val expectedPart = File(
            retained.mirrorRoot,
            "${RdpSafDocumentsAdapter.TO_REMOTE}/.permission-denied.part",
        )
        assertEquals(expectedPart.canonicalFile, documents.retainedPart.canonicalFile)
        assertTrue(expectedPart.isFile)
        assertEquals(0L, expectedPart.length())
        assertEquals(0, documents.providerEffects)

        val ownerProbe = Any()
        assertFalse(owner.tryAcquire(ownerProbe))
        val sameProcessSuccessor = MethodResult()
        first.prepare(prepareRequest(SECOND_REQUEST_ID), sameProcessSuccessor)
        sameProcessSuccessor.await()
        assertEquals("busy", sameProcessSuccessor.code)
        first.close()

        val coldDocuments = Documents(RdpSafCandidateSet.None)
        val cold = coordinator(
            activity,
            journal,
            manager(root, journal, coldDocuments, THIRD_EPOCH),
            RdpSafProcessOwner(THIRD_EPOCH),
            { true },
        )
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)
        assertTrue(expectedPart.isFile)
        assertEquals(0, coldDocuments.inspections)
        assertEquals(0, coldDocuments.creates)
        assertEquals(0, coldDocuments.writes)

        val coldSuccessor = MethodResult()
        cold.prepare(prepareRequest(SECOND_REQUEST_ID), coldSuccessor)
        coldSuccessor.await()
        assertEquals("busy", coldSuccessor.code)
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)
        assertTrue(expectedPart.isFile)
        cold.close()
    }

    @Test
    fun sameProcessReplacementCannotReadBackWhileOldProviderWriteIsStillLive() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = Files.createTempDirectory("saf-coordinator-live-write").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val owner = RdpSafProcessOwner(NEW_EPOCH)
        val oldDocuments = Documents(RdpSafCandidateSet.None, blockWrite = true)
        val drive = completeSealedRecord(
            journal,
            root,
            identity(NEW_EPOCH),
            dispatched = false,
        )
        val old = coordinator(
            activity,
            journal,
            manager(root, journal, oldDocuments, NEW_EPOCH),
            owner,
            { true },
        )

        val save = MethodResult()
        old.save(lifecycleRequest(), save)
        assertTrue(oldDocuments.writeEntered.await(2, TimeUnit.SECONDS))
        old.close()

        val replacementDocuments = Documents(RdpSafCandidateSet.One(document()))
        val replacement = coordinator(
            activity,
            journal,
            manager(root, journal, replacementDocuments, NEW_EPOCH),
            owner,
            { true },
        )
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(0, replacementDocuments.inspections)
        assertTrue(drive.exists())

        val successor = MethodResult()
        replacement.prepare(prepareRequest(SECOND_REQUEST_ID), successor)
        successor.await()
        assertEquals("busy", successor.code)
        oldDocuments.releaseWrite.countDown()
        replacement.close()
    }

    @Test
    fun quiescedSameProcessReplacementKeepsUnknownWithoutAutomaticReadback() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = Files.createTempDirectory("saf-coordinator-same-process").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        completeSealedRecord(journal, root, identity(NEW_EPOCH))
        journal.fileUnknown(identity(NEW_EPOCH), FILE_NAME)
        val owner = RdpSafProcessOwner(NEW_EPOCH)
        val first = coordinator(
            activity,
            journal,
            manager(root, journal, Documents(RdpSafCandidateSet.None), NEW_EPOCH),
            owner,
            { true },
        )
        first.close()

        val replacementDocuments = Documents(RdpSafCandidateSet.One(document()))
        val replacement = coordinator(
            activity,
            journal,
            manager(root, journal, replacementDocuments, NEW_EPOCH),
            owner,
            { true },
        )
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(0, replacementDocuments.inspections)
        assertEquals(RdpSafTransferPhase.UNKNOWN, store.value?.phase)
        replacement.close()
    }

    @Test
    fun explicitObservationReadsBackDispatchedChildBeforePublishingSealed() {
        val foreground = AtomicBoolean(false)
        val fixture = fixture(
            RdpSafCandidateSet.One(document()),
            persistTransferUnknown = false,
            foreground = foreground,
        )
        foreground.set(true)

        val observed = MethodResult()
        fixture.coordinator.observe(lifecycleRequest(), observed)
        observed.await()

        assertEquals(null, observed.code)
        assertEquals("saved", (observed.value as Map<*, *>)["state"])
        assertEquals(1, fixture.documents.inspections)
        assertEquals(1, fixture.documents.readbacks)
        assertEquals(RdpSafTransferPhase.DISCARDED, fixture.store.value?.phase)
        fixture.coordinator.close()
    }

    @Test
    fun completeObservationCleansMirrorBeforeAllowingSuccessor() {
        val fixture = completeFixture(cleanupFails = false)
        val observed = MethodResult()
        fixture.coordinator.observe(lifecycleRequest(), observed)
        observed.await()

        assertEquals("saved", (observed.value as Map<*, *>)["state"])
        assertEquals(RdpSafTransferPhase.DISCARDED, fixture.store.value?.phase)
        assertTrue(!fixture.drive.exists())

        val successor = MethodResult()
        fixture.coordinator.prepare(prepareRequest(SECOND_REQUEST_ID), successor)
        successor.await()
        assertEquals(null, successor.code)
        fixture.coordinator.close()
    }

    @Test
    fun failedCompleteCleanupBecomesStickyUnknownAndBlocksSuccessor() {
        val fixture = completeFixture(cleanupFails = true)
        val observed = MethodResult()
        fixture.coordinator.observe(lifecycleRequest(), observed)
        observed.await()

        assertEquals("unknown", (observed.value as Map<*, *>)["state"])
        assertEquals(RdpSafTransferPhase.DISCARD_INTENT, fixture.store.value?.phase)

        val successor = MethodResult()
        fixture.coordinator.prepare(prepareRequest(SECOND_REQUEST_ID), successor)
        successor.await()
        assertEquals("busy", successor.code)
        fixture.coordinator.close()
    }

    @Test
    fun bridgeRetireThenDisposeWaitsForExactNativeDrainBeforeOwnerRelease() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = Files.createTempDirectory("saf-coordinator-pending-native").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val owner = RdpSafProcessOwner(NEW_EPOCH)
        val first = coordinator(
            activity,
            journal,
            manager(root, journal, Documents(RdpSafCandidateSet.None), NEW_EPOCH),
            owner,
            { true },
            closeWaitMs = 1_000,
        )
        val prepared = MethodResult()
        first.prepare(prepareRequest(SESSION_REQUEST_ID), prepared)
        prepared.await()
        val transferId = (prepared.value as Map<*, *>)["transferId"] as String
        val session = BlockingSession(
            RdpNativeFileTransferEndpoint(
                transferId,
                SESSION_REQUEST_ID,
                SESSION_REVISION,
                File(root, "$transferId/root").canonicalPath,
            ),
        )
        first.sessionOpened(session)
        // This is the exact production RdpNativeBridge disposal order:
        // retire() calls transportRetiring(session), then session.close(), then dispose()
        // calls coordinator.close(). The coordinator must retain that exact session across it.
        first.transportRetiring(session)
        session.close()
        val startedAt = System.nanoTime()
        first.close()
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt) < 100)
        assertTrue(session.drainEntered.await(2, TimeUnit.SECONDS))

        val probe = Any()
        assertFalse(owner.tryAcquire(probe))

        session.releaseDrain.countDown()
        val acquired = AtomicBoolean(false)
        awaitCondition {
            if (!acquired.get() && owner.tryAcquire(probe)) acquired.set(true)
            acquired.get()
        }
        owner.release(probe)
    }

    @Test
    fun lateNativeDrainCannotReleaseProcessOwnerAfterDisposeDeadline() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = Files.createTempDirectory("saf-coordinator-late-native").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val owner = RdpSafProcessOwner(NEW_EPOCH)
        val coordinator = coordinator(
            activity,
            journal,
            manager(root, journal, Documents(RdpSafCandidateSet.None), NEW_EPOCH),
            owner,
            { true },
            closeWaitMs = 25,
        )
        val prepared = MethodResult()
        coordinator.prepare(prepareRequest(SESSION_REQUEST_ID), prepared)
        prepared.await()
        val transferId = (prepared.value as Map<*, *>)["transferId"] as String
        val session = BlockingSession(
            RdpNativeFileTransferEndpoint(
                transferId,
                SESSION_REQUEST_ID,
                SESSION_REVISION,
                File(root, "$transferId/root").canonicalPath,
            ),
        )
        coordinator.sessionOpened(session)
        coordinator.transportRetiring(session)
        session.close()
        coordinator.close()
        assertTrue(session.drainEntered.await(2, TimeUnit.SECONDS))
        Thread.sleep(50)
        session.releaseDrain.countDown()
        Thread.sleep(50)

        val probe = Any()
        assertFalse(owner.tryAcquire(probe))
    }

    @Test
    fun coldCompleteBlocksDirectPrepareUntilCleanupIsDurablyDiscarded() {
        val fixture = completeFixture(cleanupFails = false)
        val first = MethodResult()
        fixture.coordinator.prepare(prepareRequest(SECOND_REQUEST_ID), first)
        first.await()
        assertEquals("busy", first.code)

        awaitCondition { fixture.store.value?.phase == RdpSafTransferPhase.DISCARDED }
        val retry = MethodResult()
        fixture.coordinator.prepare(prepareRequest(SECOND_REQUEST_ID), retry)
        retry.await()
        assertEquals(null, retry.code)
        assertEquals("prepared", (retry.value as Map<*, *>)["state"])
        fixture.coordinator.close()
    }

    @Test
    fun failedColdCompleteCleanupSurvivesRestartAndBlocksPrepareUntilRetried() {
        val first = completeFixture(cleanupFails = true)
        awaitCondition { first.store.value?.phase == RdpSafTransferPhase.DISCARD_INTENT }
        val blocked = MethodResult()
        first.coordinator.prepare(prepareRequest(SECOND_REQUEST_ID), blocked)
        blocked.await()
        assertEquals("busy", blocked.code)
        first.coordinator.close()

        assertTrue(first.drive.resolve("unsafe-link").delete())
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val journal = RdpSafTransferJournal(first.store)
        val root = first.drive.parentFile!!.parentFile!!
        val replacement = coordinator(
            activity,
            journal,
            manager(root, journal, Documents(RdpSafCandidateSet.None), THIRD_EPOCH),
            RdpSafProcessOwner(THIRD_EPOCH),
            { true },
        )
        awaitCondition { first.store.value?.phase == RdpSafTransferPhase.DISCARDED }

        val successor = MethodResult()
        replacement.prepare(prepareRequest(SECOND_REQUEST_ID), successor)
        successor.await()
        assertEquals(null, successor.code)
        assertEquals("prepared", (successor.value as Map<*, *>)["state"])
        replacement.close()
    }

    private data class Fixture(
        val coordinator: RdpSafTransferCoordinator,
        val store: Store,
        val documents: Documents,
        val coldGrantResolutions: AtomicInteger,
    )

    private data class CompleteFixture(
        val coordinator: RdpSafTransferCoordinator,
        val store: Store,
        val drive: File,
    )

    private fun fixture(
        candidate: RdpSafCandidateSet,
        coldGrantAvailable: Boolean = true,
        persistTransferUnknown: Boolean = true,
        foreground: AtomicBoolean = AtomicBoolean(true),
    ): Fixture {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = Files.createTempDirectory("saf-coordinator-recover").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val documents = Documents(candidate)
        val drive = File(root, "$TRANSFER_ID/root").apply { mkdirs() }
        val received = File(drive, RdpSafDocumentsAdapter.FROM_REMOTE).apply { mkdirs() }
            .resolve(FILE_NAME).apply { writeBytes(ByteArray(72) { 9 }) }
        journal.create(identity(), drive)
        journal.prepared(identity(), emptyList())
        journal.closeRequested(identity())
        journal.sealed(identity(), "f".repeat(32), listOf(received.sealed()))
        journal.beginFileCommit(identity(), FILE_NAME)
        journal.createDispatched(identity(), FILE_NAME)
        journal.created(identity(), FILE_NAME, DOCUMENT_URI.toString())
        journal.writeDispatched(identity(), FILE_NAME)
        if (persistTransferUnknown) journal.fileUnknown(identity(), FILE_NAME)
        val manager = RdpSafMirrorManager(
            root,
            journal,
            documents,
            object : RdpSafNativeDrain {
                override fun close(
                    identity: RdpSafTransferIdentity,
                    callback: (kotlin.Result<RdpSafNativeCloseReceipt>) -> Unit,
                ) = error("recovery must not drain native transport")
            },
            NEW_EPOCH,
        )
        val grant = grant()
        val coldGrantResolutions = AtomicInteger()
        val coordinator = RdpSafTransferCoordinator(
            activity = activity,
            grants = RdpSafGrantBroker(activity),
            foreground = foreground::get,
            clearSession = {},
            main = Handler(Looper.getMainLooper()),
            processEpochOverride = NEW_EPOCH,
            journalOverride = journal,
            managerOverride = manager,
            grantResolverOverride = {
                authority: RdpSafAuthority, grantId: String, grantRevision: Long ->
                check(authority.authorityId == AUTHORITY_ID)
                check(grantId == GRANT_ID && grantRevision == GRANT_REVISION)
                grant
            },
            coldGrantResolverOverride = { identity: RdpSafTransferIdentity ->
                coldGrantResolutions.incrementAndGet()
                check(identity.authorityId == AUTHORITY_ID)
                check(identity.grantId == GRANT_ID && identity.grantRevision == GRANT_REVISION)
                if (!coldGrantAvailable) throw RdpSafFailure("authority_changed")
                grant
            },
        )
        return Fixture(coordinator, store, documents, coldGrantResolutions)
    }

    private fun completeFixture(cleanupFails: Boolean): CompleteFixture {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = Files.createTempDirectory("saf-coordinator-complete").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val drive = completeSealedRecord(journal, root, identity())
        journal.verified(identity(), FILE_NAME)
        if (cleanupFails) {
            Files.createSymbolicLink(drive.resolve("unsafe-link").toPath(), root.toPath())
        }
        val owner = RdpSafProcessOwner(NEW_EPOCH)
        val coordinator = coordinator(
            activity,
            journal,
            manager(root, journal, Documents(RdpSafCandidateSet.None), NEW_EPOCH),
            owner,
            { true },
        )
        return CompleteFixture(coordinator, store, drive)
    }

    private fun completeSealedRecord(
        journal: RdpSafTransferJournal,
        root: File,
        identity: RdpSafTransferIdentity,
        dispatched: Boolean = true,
    ): File {
        val drive = File(root, "${identity.transferId}/root").apply { mkdirs() }
        val received = File(drive, RdpSafDocumentsAdapter.FROM_REMOTE).apply { mkdirs() }
            .resolve(FILE_NAME).apply { writeBytes(ByteArray(72) { 9 }) }
        journal.create(identity, drive)
        journal.prepared(identity, emptyList())
        journal.closeRequested(identity)
        journal.sealed(identity, "f".repeat(32), listOf(received.sealed()))
        if (dispatched) {
            journal.beginFileCommit(identity, FILE_NAME)
            journal.createDispatched(identity, FILE_NAME)
            journal.created(identity, FILE_NAME, DOCUMENT_URI.toString())
            journal.writeDispatched(identity, FILE_NAME)
        }
        return drive
    }

    private fun manager(
        root: File,
        journal: RdpSafTransferJournal,
        documents: RdpSafDocumentsPort,
        epoch: String,
    ) = RdpSafMirrorManager(
        root,
        journal,
        documents,
        object : RdpSafNativeDrain {
            override fun close(
                identity: RdpSafTransferIdentity,
                callback: (kotlin.Result<RdpSafNativeCloseReceipt>) -> Unit,
            ) = error("test does not drain native transport")
        },
        epoch,
    )

    private fun coordinator(
        activity: Activity,
        journal: RdpSafTransferJournal,
        manager: RdpSafMirrorManager,
        owner: RdpSafProcessOwner,
        foreground: () -> Boolean,
        closeWaitMs: Long = 250,
    ) = RdpSafTransferCoordinator(
        activity = activity,
        grants = RdpSafGrantBroker(activity),
        foreground = foreground,
        clearSession = {},
        main = Handler(Looper.getMainLooper()),
        journalOverride = journal,
        managerOverride = manager,
        grantResolverOverride = { _, _, _ -> grant() },
        coldGrantResolverOverride = { grant() },
        processOwnerOverride = owner,
        processOwnerCloseWaitMs = closeWaitMs,
    )

    private fun awaitCondition(condition: () -> Boolean) {
        repeat(400) {
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) return
            Thread.sleep(5)
        }
        error("condition deadline")
    }

    private fun prepareRequest(requestId: String) = mapOf(
        "schemaVersion" to 6,
        "requestId" to requestId,
        "authority" to authorityWire(),
        "grantId" to GRANT_ID,
        "grantRevision" to GRANT_REVISION,
        "sessionRequestId" to SESSION_REQUEST_ID,
        "sessionRevision" to SESSION_REVISION,
    )

    private fun lifecycleRequest() = prepareRequest(SESSION_REQUEST_ID) + mapOf(
        "transferId" to TRANSFER_ID,
    )

    private fun authorityWire() = mapOf(
        "schemaVersion" to 5,
        "namespaceDigest" to NAMESPACE,
        "profileRef" to PROFILE,
        "profileRevision" to PROFILE_REVISION,
    )

    private fun identity(epoch: String = OLD_EPOCH) = RdpSafTransferIdentity(
        TRANSFER_ID,
        AUTHORITY_ID,
        GRANT_ID,
        GRANT_REVISION,
        SESSION_REQUEST_ID,
        SESSION_REVISION,
        epoch,
    )

    private fun grant() = RdpSafActiveGrant(
        AUTHORITY_ID,
        GRANT_ID,
        GRANT_REVISION,
        Uri.parse("content://owned/tree"),
    )

    private fun document() = RdpSafDocument(
        DOCUMENT_URI,
        FILE_NAME,
        "application/octet-stream",
        72,
        0,
    )

    private fun File.sealed() = RdpSafSealedFile(
        name,
        length(),
        MessageDigest.getInstance("SHA-256").digest(readBytes())
            .joinToString("") { "%02x".format(it) },
        this,
    )

    companion object {
        private const val SECOND_REQUEST_ID = "12345678-1234-4abc-8def-1234567890ac"
        private const val SESSION_REQUEST_ID = "87654321-4321-4abc-8def-ba0987654321"
        private const val SESSION_REVISION = 9L
        private val GRANT_ID = "1".repeat(32)
        private const val GRANT_REVISION = 8L
        private val TRANSFER_ID = "2".repeat(32)
        private val NAMESPACE = "a".repeat(64)
        private val PROFILE = "b".repeat(64)
        private const val PROFILE_REVISION = 7L
        private val AUTHORITY_ID = RdpSafContract.authority(mapOf(
            "schemaVersion" to 5,
            "namespaceDigest" to NAMESPACE,
            "profileRef" to PROFILE,
            "profileRevision" to PROFILE_REVISION,
        )).authorityId
        private val OLD_EPOCH = "c".repeat(32)
        private val NEW_EPOCH = "d".repeat(32)
        private val THIRD_EPOCH = "e".repeat(32)
        private const val FILE_NAME = "larenor-download.bin"
        private val DOCUMENT_URI = Uri.parse("content://owned/document/1")
    }
}
