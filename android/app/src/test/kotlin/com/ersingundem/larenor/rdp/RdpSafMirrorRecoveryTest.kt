package com.ersingundem.larenor.rdp

import android.net.Uri
import android.os.CancellationSignal
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@org.junit.runner.RunWith(org.robolectric.RobolectricTestRunner::class)
@org.robolectric.annotation.Config(sdk = [35], manifest = org.robolectric.annotation.Config.NONE)
class RdpSafMirrorRecoveryTest {
    private class Store : RdpSafTransferStore {
        var value: RdpSafTransferRecord? = null
        override fun read() = value
        override fun replace(value: RdpSafTransferRecord) { this.value = value }
        override fun clear(expectedTransferId: String) { value = null }
    }

    private class Documents(var candidate: RdpSafCandidateSet) : RdpSafDocumentsPort {
        var creates = 0
        var writes = 0
        var readbacks = 0
        override fun snapshotToRemote(treeUri: Uri, targetDirectory: File, cancel: CancellationSignal) = emptyList<RdpSafSealedFile>()
        override fun inspectSaveCandidate(treeUri: Uri, name: String, cancel: CancellationSignal) = candidate
        override fun createForSave(treeUri: Uri, name: String, cancel: CancellationSignal): RdpSafDocument {
            creates++
            error("recovery must not create")
        }
        override fun writeOnce(document: RdpSafDocument, source: RdpSafSealedFile, cancel: CancellationSignal) {
            writes++
            error("recovery must not write")
        }
        override fun readback(document: RdpSafDocument, expected: RdpSafSealedFile, cancel: CancellationSignal): Boolean {
            readbacks++
            return true
        }
    }

    @Test
    fun exactOneCandidateAndHashProofRecoversWithoutCreateOrWrite() {
        val fixture = fixture(RdpSafCandidateSet.One(document()))

        val result = await { fixture.manager.recoverDispatchedSave(identity(), grant(), it) }

        assertTrue(result is RdpSafMirrorResult.Saved)
        assertEquals(RdpSafTransferPhase.COMPLETE, fixture.store.value?.phase)
        assertEquals(0, fixture.documents.creates)
        assertEquals(0, fixture.documents.writes)
        assertEquals(1, fixture.documents.readbacks)
        fixture.manager.close()
    }

    @Test
    fun zeroOrMultipleCandidateRecoveryStaysUnknownWithoutExternalEffect() {
        for (candidate in listOf(RdpSafCandidateSet.None, RdpSafCandidateSet.Multiple)) {
            val fixture = fixture(candidate)

            val result = await { fixture.manager.recoverDispatchedSave(identity(), grant(), it) }

            assertTrue(result is RdpSafMirrorResult.Unknown)
            assertEquals(RdpSafTransferPhase.UNKNOWN, fixture.store.value?.phase)
            assertEquals(0, fixture.documents.creates)
            assertEquals(0, fixture.documents.writes)
            assertEquals(0, fixture.documents.readbacks)
            fixture.manager.close()
        }
    }

    private data class Fixture(
        val manager: RdpSafMirrorManager,
        val store: Store,
        val documents: Documents,
    )

    private fun fixture(candidate: RdpSafCandidateSet): Fixture {
        val root = Files.createTempDirectory("saf-stage2-recover").toFile()
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        val documents = Documents(candidate)
        val drive = File(root, "${identity().transferId}/root").apply { mkdirs() }
        val received = File(drive, RdpSafDocumentsAdapter.FROM_REMOTE).apply { mkdirs() }
            .resolve("larenor-download.bin").apply { writeBytes(ByteArray(72) { 9 }) }
        journal.create(identity(), drive)
        journal.prepared(identity(), emptyList())
        journal.closeRequested(identity())
        journal.sealed(identity(), "f".repeat(32), listOf(received.sealed()))
        journal.beginFileCommit(identity(), received.name)
        journal.createDispatched(identity(), received.name)
        journal.fileUnknown(identity(), received.name)
        val manager = RdpSafMirrorManager(
            root,
            journal,
            documents,
            object : RdpSafNativeDrain {
                override fun close(
                    identity: RdpSafTransferIdentity,
                    callback: (Result<RdpSafNativeCloseReceipt>) -> Unit,
                ) = error("not used")
            },
            EPOCH,
        )
        return Fixture(manager, store, documents)
    }

    private fun await(start: ((RdpSafMirrorResult) -> Unit) -> Unit): RdpSafMirrorResult {
        val latch = CountDownLatch(1)
        var result: RdpSafMirrorResult? = null
        start { result = it; latch.countDown() }
        assertTrue(latch.await(2, TimeUnit.SECONDS))
        return result!!
    }

    private fun document() = RdpSafDocument(
        Uri.parse("content://owned/document/1"),
        "larenor-download.bin",
        "application/octet-stream",
        72,
        0,
    )
    private fun identity() = RdpSafTransferIdentity(
        "a".repeat(32), "b".repeat(64), "c".repeat(32), 1,
        "11111111-1111-4111-8111-111111111111", 1, EPOCH,
    )
    private fun grant() = RdpSafActiveGrant("b".repeat(64), "c".repeat(32), 1, Uri.parse("content://owned/tree"))
    private fun File.sealed() = RdpSafSealedFile(
        name, length(), java.security.MessageDigest.getInstance("SHA-256").digest(readBytes())
            .joinToString("") { "%02x".format(it) }, this,
    )

    companion object { private val EPOCH = "e".repeat(32) }
}
