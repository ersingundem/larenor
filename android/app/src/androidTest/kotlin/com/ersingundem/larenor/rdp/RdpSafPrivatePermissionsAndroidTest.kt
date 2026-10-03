package com.ersingundem.larenor.rdp

import android.content.Context
import android.system.Os
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import javax.crypto.KeyGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RdpSafPrivatePermissionsAndroidTest {
    @Test
    fun productionSyscallsSetGrantTransferRootsLedgersAndMirrorFileModes() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val sandbox = File(
            context.noBackupFilesDir,
            "rdp-saf-permission-${System.nanoTime()}",
        )
        assertTrue(sandbox.mkdir())
        try {
            val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            val grantRoot = File(sandbox, "grants")
            val grantStore = RdpSafGrantStore(
                context,
                testKeyProvider = { key },
                rootOverride = grantRoot,
            )
            val grant = RdpSafGrantRecord(
                authority = RdpSafAuthority.create("a".repeat(64), "b".repeat(64), 1),
                grantId = "c".repeat(32),
                grantRevision = 1,
                phase = RdpSafGrantPhase.PREPARED,
                selectRequestId = "11111111-1111-4111-8111-111111111111",
                createdAtMs = 1_000,
                expiresAtMs = 31_000,
                uri = "content://owned/tree/document",
                requiredFlags = RdpSafGrantBroker.REQUIRED_FLAGS,
                preexistingFlags = 0,
                acquiredFlags = RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS,
                activationRequestId = null,
                retirementRequestId = null,
            )
            grantStore.replace(listOf(grant))
            assertEquals(listOf(grant), grantStore.read())

            val mirrorRoot = File(sandbox, "mirror")
            assertTrue(mirrorRoot.mkdir())
            val transferRoot = File(sandbox, "transfers")
            val transferStore = RdpSafEncryptedTransferStore(
                context,
                testKeyProvider = { key },
                rootOverride = transferRoot,
            )
            val transfer = RdpSafTransferRecord(
                identity = RdpSafTransferIdentity(
                    transferId = "d".repeat(32),
                    authorityId = grant.authority.authorityId,
                    grantId = grant.grantId,
                    grantRevision = grant.grantRevision,
                    sessionRequestId = "22222222-2222-4222-8222-222222222222",
                    sessionRevision = 1,
                    processEpoch = "e".repeat(32),
                ),
                mirrorRoot = mirrorRoot.canonicalPath,
                phase = RdpSafTransferPhase.PREPARING,
            )
            transferStore.replace(transfer)
            assertEquals(transfer, transferStore.read())

            assertMode(grantRoot, RDP_SAF_PRIVATE_DIRECTORY_MODE)
            assertMode(grantStore.fileForTest, RDP_SAF_PRIVATE_FILE_MODE)
            assertMode(transferRoot, RDP_SAF_PRIVATE_DIRECTORY_MODE)
            assertMode(File(transferRoot, "journal.enc"), RDP_SAF_PRIVATE_FILE_MODE)

            val mirrorPart = File(mirrorRoot, "owned.part")
            openPrivateMirrorPart(mirrorPart).use { stream ->
                stream.write(byteArrayOf(1, 2, 3))
                stream.fd.sync()
            }
            assertMode(mirrorPart, RDP_SAF_PRIVATE_FILE_MODE)
        } finally {
            sandbox.deleteRecursively()
        }
    }

    private fun assertMode(value: File, expected: Int) {
        assertEquals(expected, Os.stat(value.absolutePath).st_mode and 0x1ff)
    }
}
