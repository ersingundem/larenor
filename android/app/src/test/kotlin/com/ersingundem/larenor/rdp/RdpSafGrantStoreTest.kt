package com.ersingundem.larenor.rdp

import android.app.Application
import java.io.File
import java.nio.file.Files
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpSafGrantStoreTest {
    @Test
    fun encryptedAtomicLedgerSurvivesRestartWithoutLeakingUri() {
        val fixture = fixture()
        val record = record(uri = "content://owned/tree/private-document")
        fixture.store.replace(listOf(record))

        val raw = fixture.store.fileForTest.readBytes()
        assertFalse(raw.decodeToString().contains("content://"))
        assertEquals(listOf(record), fixture.reopen().read())
    }


    @Test
    fun permissionApplicatorRunsBeforeAtomicPayloadAndAfterFinalRename() {
        val root = File(
            RuntimeEnvironment.getApplication().cacheDir,
            "rdp-saf-permission-order-${System.nanoTime()}",
        )
        val events = mutableListOf<String>()
        lateinit var store: RdpSafGrantStore
        val permissions = RdpSafPrivatePermissions(
            descriptor = RdpSafDescriptorPermission { _, mode ->
                assertEquals(RDP_SAF_PRIVATE_FILE_MODE, mode)
                val files = root.listFiles()?.filter { it.isFile }.orEmpty()
                assertEquals(1, files.size)
                assertTrue(files.single().name.endsWith(".new"))
                assertEquals(0L, files.single().length())
                assertFalse(store.fileForTest.exists())
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
                        assertEquals(store.fileForTest.canonicalFile, value.canonicalFile)
                        assertTrue(value.isFile)
                        assertTrue(value.length() > 0)
                        assertFalse(File(root, "ledger.enc.new").exists())
                        events += "path:file"
                    }
                    else -> fail("Unexpected mode $mode")
                }
            },
        )
        val key = key()
        store = RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
            permissions = permissions,
        )

        store.replace(listOf(record()))

        assertEquals(listOf("path:directory", "descriptor:file", "path:file"), events)
        assertEquals(listOf(record()), RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
        ).read())
    }

    @Test
    fun permissionFailuresFailClosedWithoutPublishingOrDeletingDurableEvidence() {
        val root = File(
            RuntimeEnvironment.getApplication().cacheDir,
            "rdp-saf-permission-failure-${System.nanoTime()}",
        )
        val key = key()
        val descriptorFailure = RdpSafPrivatePermissions(
            descriptor = RdpSafDescriptorPermission { _, _ -> throw IllegalStateException("denied") },
            path = RdpSafPathPermission { _, _ -> },
        )
        val preWrite = RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
            permissions = descriptorFailure,
        )

        rejectUnavailable { preWrite.replace(listOf(record())) }
        assertFalse(preWrite.fileForTest.exists())
        assertTrue(root.listFiles()?.none { it.isFile } != false)

        val finalPathFailure = RdpSafPrivatePermissions(
            descriptor = RdpSafDescriptorPermission { _, _ -> },
            path = RdpSafPathPermission { path, mode ->
                if (mode == RDP_SAF_PRIVATE_FILE_MODE && File(path).name == "ledger.enc") {
                    throw IllegalStateException("denied")
                }
            },
        )
        val postRename = RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
            permissions = finalPathFailure,
        )
        rejectUnavailable { postRename.replace(listOf(record())) }
        assertTrue(postRename.fileForTest.isFile)
        assertEquals(listOf(record()), RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
        ).read())
    }

    @Test
    fun tamperWrongKeyAndSymlinkFailClosedWithoutDeletingEvidence() {
        val fixture = fixture()
        fixture.store.replace(listOf(record()))
        val original = fixture.store.fileForTest.readBytes()
        fixture.store.fileForTest.writeBytes(original.copyOf().also { it[it.lastIndex] = (it.last() + 1).toByte() })
        rejectUnavailable { fixture.store.read() }
        assertTrue(fixture.store.fileForTest.exists())

        fixture.store.fileForTest.writeBytes(original)
        val wrong = RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key() },
            rootOverride = fixture.root,
        )
        rejectUnavailable { wrong.read() }

        fixture.store.fileForTest.delete()
        val outside = File(fixture.root.parentFile, "outside-${System.nanoTime()}").apply {
            writeText("foreign")
        }
        Files.createSymbolicLink(fixture.store.fileForTest.toPath(), outside.toPath())
        rejectUnavailable { fixture.store.read() }
        assertEquals("foreign", outside.readText())
    }

    @Test
    fun strictLedgerRejectsCapacityDuplicateAndUntrustedFieldsBeforeMutation() {
        val fixture = fixture()
        val authority = authority()
        fixture.store.replace(List(RdpSafGrantStore.MAX_PER_AUTHORITY) { index ->
            record(
                authority = authority,
                grantId = "%032x".format(index + 1),
                selectRequestId = uuid(index + 1),
            )
        })
        val before = fixture.store.fileForTest.readBytes()
        rejectUnavailable {
            fixture.store.replace(fixture.store.read() + record(
                authority = authority,
                grantId = "f".repeat(32),
                selectRequestId = uuid(99),
            ))
        }
        assertTrue(before.contentEquals(fixture.store.fileForTest.readBytes()))

        rejectUnavailable { fixture.store.replace(listOf(record(), record())) }
        assertTrue(before.contentEquals(fixture.store.fileForTest.readBytes()))
    }

    @Test
    fun declaredGlobalCapacityFitsBoundedMaximumUriEnvelope() {
        val fixture = fixture()
        val maximumUri = "content://" + "x".repeat(4096 - "content://".length)
        val records = List(RdpSafGrantStore.MAX_GLOBAL) { index ->
            val authorityGroup = index / RdpSafGrantStore.MAX_PER_AUTHORITY + 1
            record(
                authority = RdpSafAuthority.create(
                    "%064x".format(authorityGroup),
                    "b".repeat(64),
                    1,
                ),
                grantId = "%032x".format(index + 1),
                selectRequestId = uuid(index + 1),
                uri = maximumUri,
            ).copy(grantRevision = (index + 1).toLong())
        }

        fixture.store.replace(records)

        assertEquals(RdpSafGrantStore.MAX_GLOBAL, fixture.reopen().read().size)
        assertTrue(fixture.store.fileForTest.length() < 2L * 1024 * 1024)
    }

    private data class Fixture(
        val root: File,
        val key: SecretKey,
        val store: RdpSafGrantStore,
    ) {
        fun reopen() = RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
        )
    }

    private fun fixture(): Fixture {
        val root = File(
            RuntimeEnvironment.getApplication().cacheDir,
            "rdp-saf-${System.nanoTime()}",
        )
        val key = key()
        return Fixture(root, key, RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
        ))
    }

    private fun key(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    private fun authority() = RdpSafAuthority.create("a".repeat(64), "b".repeat(64), 1)

    private fun record(
        authority: RdpSafAuthority = authority(),
        grantId: String = "0".repeat(32),
        selectRequestId: String = uuid(1),
        uri: String = "content://owned/tree/document",
    ) = RdpSafGrantRecord(
        authority = authority,
        grantId = grantId,
        grantRevision = 1,
        phase = RdpSafGrantPhase.PREPARED,
        selectRequestId = selectRequestId,
        createdAtMs = 1_000,
        expiresAtMs = 31_000,
        uri = uri,
        requiredFlags = RdpSafGrantBroker.REQUIRED_FLAGS,
        preexistingFlags = 0,
        acquiredFlags = RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS,
        activationRequestId = null,
        retirementRequestId = null,
    )

    private fun uuid(index: Int) = "00000000-0000-4000-8000-${index.toString().padStart(12, '0')}"

    private fun rejectUnavailable(block: () -> Unit) {
        try {
            block()
            fail("Expected unavailable")
        } catch (failure: RdpSafFailure) {
            assertEquals("unavailable", failure.code)
        }
    }

}
