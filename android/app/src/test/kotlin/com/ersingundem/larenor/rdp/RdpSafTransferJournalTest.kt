package com.ersingundem.larenor.rdp

import java.io.File
import java.nio.file.Files
import javax.crypto.KeyGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.robolectric.RuntimeEnvironment

@org.junit.runner.RunWith(org.robolectric.RobolectricTestRunner::class)
@org.robolectric.annotation.Config(sdk = [35], manifest = org.robolectric.annotation.Config.NONE)
class RdpSafTransferJournalTest {
    private class Store : RdpSafTransferStore {
        var value: RdpSafTransferRecord? = null
        val writes = mutableListOf<RdpSafTransferRecord>()
        override fun read() = value
        override fun replace(value: RdpSafTransferRecord) {
            this.value = value
            writes += value
        }
        override fun clear(expectedTransferId: String) {
            check(value?.identity?.transferId == expectedTransferId)
            value = null
        }
    }

    @Test
    fun nativeCloseOnlySealsAndSaveEffectsAreDurablyOrdered() {
        val root = Files.createTempDirectory("saf-stage2-journal").toFile()
        val mirror = File(root, "LrnXfer").apply { mkdir() }
        val upload = File(root, "upload").apply { writeBytes(byteArrayOf(1)) }
        val download = File(root, "download").apply { writeBytes(byteArrayOf(2)) }
        val store = Store()
        val journal = RdpSafTransferJournal(store)

        journal.create(identity(), mirror)
        journal.prepared(identity(), listOf(upload.sealed("u.bin")))
        journal.closeRequested(identity())
        val closed = journal.sealed(identity(), "c".repeat(32), listOf(download.sealed("d.bin")))

        assertEquals(RdpSafTransferPhase.SEALED, closed.phase)
        assertEquals(RdpSafFileCommitPhase.SEALED_PRIVATE, closed.fromRemote.single().phase)
        journal.beginFileCommit(identity(), "d.bin")
        journal.createDispatched(identity(), "d.bin")
        journal.created(identity(), "d.bin", "content://owned/document/1")
        journal.writeDispatched(identity(), "d.bin")
        val complete = journal.verified(identity(), "d.bin")

        assertEquals(RdpSafTransferPhase.COMPLETE, complete.phase)
        assertEquals(
            listOf(
                RdpSafFileCommitPhase.SEALED_PRIVATE,
                RdpSafFileCommitPhase.SAF_COMMIT_INTENT,
                RdpSafFileCommitPhase.SAF_CREATE_DISPATCHED,
                RdpSafFileCommitPhase.SAF_CREATED,
                RdpSafFileCommitPhase.SAF_WRITE_DISPATCHED,
                RdpSafFileCommitPhase.SAF_VERIFIED,
            ),
            store.writes.mapNotNull { it.fromRemote.singleOrNull()?.phase }.distinct(),
        )
    }

    @Test
    fun priorProcessActiveSessionBecomesUnknownAndCannotSealOrSave() {
        val root = Files.createTempDirectory("saf-stage2-recovery").toFile()
        val mirror = File(root, "LrnXfer").apply { mkdir() }
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        journal.create(identity(), mirror)
        journal.prepared(identity(), emptyList())

        val recovered = journal.recover("e".repeat(32))

        assertEquals(RdpSafTransferPhase.UNKNOWN, recovered?.phase)
        assertThrows(IllegalStateException::class.java) {
            journal.closeRequested(identity())
        }
    }

    @Test
    fun dispatchedWriteRecoversOnlyFromExactReadbackProofWithoutReplay() {
        val root = Files.createTempDirectory("saf-stage2-readback").toFile()
        val mirror = File(root, "LrnXfer").apply { mkdir() }
        val download = File(root, "download").apply { writeBytes(byteArrayOf(2)) }
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        journal.create(identity(), mirror)
        journal.prepared(identity(), emptyList())
        journal.closeRequested(identity())
        journal.sealed(identity(), "c".repeat(32), listOf(download.sealed("d.bin")))
        journal.beginFileCommit(identity(), "d.bin")
        journal.createDispatched(identity(), "d.bin")
        journal.fileUnknown(identity(), "d.bin")

        val recovered = journal.recoveredVerified(identity(), "d.bin", "content://owned/document/1")

        assertEquals(RdpSafTransferPhase.COMPLETE, recovered.phase)
        assertEquals(RdpSafFileCommitPhase.SAF_VERIFIED, recovered.fromRemote.single().phase)
    }

    @Test
    fun combinedDirectionsShareOneCountAndByteQuota() {
        val tooMany = List(17) { record("up-$it", 1) }
        val other = List(16) { record("down-$it", 1) }
        assertThrows(IllegalArgumentException::class.java) {
            RdpSafTransferRecord(
                identity(), "/private/root", RdpSafTransferPhase.PREPARING,
                toRemote = tooMany, fromRemote = other,
            )
        }
        val tooLarge = List(5) {
            record("large-$it", RdpSafDocumentsAdapter.MAX_FILE_BYTES)
        }
        assertThrows(IllegalArgumentException::class.java) {
            RdpSafTransferRecord(
                identity(), "/private/root", RdpSafTransferPhase.PREPARING,
                toRemote = tooLarge,
            )
        }
    }

    @Test
    fun stagedMirrorFileIsHardenedBeforeFirstPayloadByteAndFailureDeletesIt() {
        val root = Files.createTempDirectory("saf-stage2-mode").toFile()
        val file = File(root, "part")
        var descriptorCalls = 0
        val recording = RdpSafPrivatePermissions(
            descriptor = RdpSafDescriptorPermission { _, mode ->
                assertEquals(RDP_SAF_PRIVATE_FILE_MODE, mode)
                assertTrue(file.isFile)
                assertEquals(0L, file.length())
                descriptorCalls += 1
            },
            path = RdpSafPathPermission { _, _ -> fail("Unexpected path permission call") },
        )

        openPrivateMirrorPart(file, recording).use { it.write(1) }

        assertEquals(1, descriptorCalls)
        assertEquals(1L, file.length())
        assertTrue(file.delete())

        val denied = File(root, "denied")
        val failing = RdpSafPrivatePermissions(
            descriptor = RdpSafDescriptorPermission { _, _ -> throw IllegalStateException("denied") },
            path = RdpSafPathPermission { _, _ -> },
        )
        assertThrows(IllegalStateException::class.java) {
            openPrivateMirrorPart(denied, failing)
        }
        assertTrue(!denied.exists())
    }

    @Test
    fun encryptedTransferJournalHardensEmptyAtomicFileBeforeWriteAndFinalFileAfterRename() {
        val root = File(
            RuntimeEnvironment.getApplication().cacheDir,
            "rdp-saf-transfer-permission-${System.nanoTime()}",
        )
        val events = mutableListOf<String>()
        val finalFile = File(root, "journal.enc")
        val permissions = RdpSafPrivatePermissions(
            descriptor = RdpSafDescriptorPermission { _, mode ->
                assertEquals(RDP_SAF_PRIVATE_FILE_MODE, mode)
                val files = root.listFiles()?.filter { it.isFile }.orEmpty()
                assertEquals(1, files.size)
                assertTrue(files.single().name.endsWith(".new"))
                assertEquals(0L, files.single().length())
                assertTrue(!finalFile.exists())
                events += "descriptor:file"
            },
            path = RdpSafPathPermission { path, mode ->
                val value = File(path)
                when (mode) {
                    RDP_SAF_PRIVATE_DIRECTORY_MODE -> {
                        assertEquals(root.canonicalFile, value.canonicalFile)
                        assertTrue(value.isDirectory)
                        events += "path:directory"
                    }
                    RDP_SAF_PRIVATE_FILE_MODE -> {
                        assertEquals(finalFile.canonicalFile, value.canonicalFile)
                        assertTrue(value.isFile)
                        assertTrue(value.length() > 0)
                        assertTrue(!File(root, "journal.enc.new").exists())
                        events += "path:file"
                    }
                    else -> fail("Unexpected mode $mode")
                }
            },
        )
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = RdpSafEncryptedTransferStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
            permissions = permissions,
        )

        store.replace(RdpSafTransferRecord(
            identity = identity(),
            mirrorRoot = File(root.parentFile, "mirror").absolutePath,
            phase = RdpSafTransferPhase.PREPARING,
        ))

        assertEquals(listOf("path:directory", "descriptor:file", "path:file"), events)
        assertEquals(RdpSafTransferPhase.PREPARING, RdpSafEncryptedTransferStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
        ).read()?.phase)
    }

    @Test
    fun completeIsCleanupDebtAndOnlyDurableDiscardedMayBeReplaced() {
        val root = Files.createTempDirectory("saf-stage2-complete-debt").toFile()
        val firstMirror = File(root, "first/LrnXfer").apply { mkdirs() }
        val store = Store()
        val journal = RdpSafTransferJournal(store)
        journal.create(identity(), firstMirror)
        journal.prepared(identity(), emptyList())
        journal.closeRequested(identity())
        journal.sealed(identity(), "c".repeat(32), emptyList())
        journal.completeEmpty(identity())
        val successor = identity().copy(
            transferId = "9".repeat(32),
            sessionRequestId = "22222222-2222-4222-8222-222222222222",
            sessionRevision = 2,
        )
        val successorMirror = File(root, "successor/LrnXfer").apply { mkdirs() }

        assertThrows(IllegalStateException::class.java) {
            journal.requirePrepareAllowed(successor)
        }
        assertThrows(IllegalStateException::class.java) {
            journal.create(successor, successorMirror)
        }
        assertEquals(identity().transferId, store.value?.identity?.transferId)
        assertEquals(RdpSafTransferPhase.COMPLETE, store.value?.phase)

        journal.beginDiscard(identity())
        journal.discarded(identity())
        journal.requirePrepareAllowed(successor)
        journal.create(successor, successorMirror)
        assertEquals(successor.transferId, store.value?.identity?.transferId)
        assertEquals(RdpSafTransferPhase.PREPARING, store.value?.phase)
    }

    private fun identity() = RdpSafTransferIdentity(
        transferId = "a".repeat(32),
        authorityId = "b".repeat(64),
        grantId = "c".repeat(32),
        grantRevision = 1,
        sessionRequestId = "11111111-1111-4111-8111-111111111111",
        sessionRevision = 1,
        processEpoch = "d".repeat(32),
    )

    private fun record(name: String, size: Long) = RdpSafTransferFileRecord(
        name = name,
        size = size,
        sha256 = "f".repeat(64),
        privatePath = "/private/$name",
        phase = RdpSafFileCommitPhase.SEALED_PRIVATE,
    )

    private fun File.sealed(name: String): RdpSafSealedFile = RdpSafSealedFile(
        name = name,
        size = length(),
        sha256 = java.security.MessageDigest.getInstance("SHA-256").digest(readBytes())
            .joinToString("") { "%02x".format(it) },
        file = this,
    )
}
