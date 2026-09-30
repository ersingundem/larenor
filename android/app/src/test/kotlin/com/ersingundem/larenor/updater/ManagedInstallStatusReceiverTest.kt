package com.ersingundem.larenor.updater

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.Signature
import android.content.pm.SigningInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ManagedInstallStatusReceiverTest {
    private lateinit var context: Context
    private lateinit var ledger: ManagedInstallLedger
    private val signature = Signature("aa".repeat(32))
    private val certificate = sha256(signature.toByteArray())

    @Before fun setUp() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("managed_client_install_v2", Context.MODE_PRIVATE)
            .edit().clear().commit()
        ledger = ManagedInstallLedger(context)
    }

    @Test fun successRequiresExactTerminalIdentityAndPackageReadback() {
        val record = submitted(sessionId = 41)
        install(version = 20, signer = signature)

        ManagedInstallStatusReceiver().onReceive(
            context,
            callback(record, PackageInstaller.STATUS_SUCCESS),
        )

        val confirmed = ManagedInstallLedger(context).read()!!
        assertEquals(ManagedInstallState.confirmed, confirmed.state)
        assertEquals(20L, confirmed.observedVersionCode)
        assertEquals(certificate, confirmed.observedCertificateSha256)
    }

    @Test fun successCallbackWithWrongInstalledVersionRemainsUnknown() {
        val record = submitted(sessionId = 42)
        install(version = 19, signer = signature)

        ManagedInstallStatusReceiver().onReceive(
            context,
            callback(record, PackageInstaller.STATUS_SUCCESS),
        )

        val unknown = ledger.read()!!
        assertEquals(ManagedInstallState.unknown, unknown.state)
        assertEquals(19L, unknown.observedVersionCode)
        try {
            ledger.requireDispatchAvailable()
            fail("Unknown delivery must block an accidental repeat")
        } catch (failure: UpdateFailure) {
            assertEquals("busy", failure.code)
        }
    }

    @Test fun failedAndCancelledCallbacksAreDistinctTerminalReceipts() {
        var record = submitted(sessionId = 43)
        ledger.acceptStatus(callback(record, PackageInstaller.STATUS_FAILURE_STORAGE)) {
            error("Package readback is forbidden for a failed callback")
        }
        assertEquals(ManagedInstallState.failed, ledger.read()!!.state)

        record = submitted(sessionId = 44, requestId = "2".repeat(32))
        ledger.acceptStatus(callback(record, PackageInstaller.STATUS_FAILURE_ABORTED)) {
            error("Package readback is forbidden for a cancelled callback")
        }
        assertEquals(ManagedInstallState.cancelled, ledger.read()!!.state)
    }

    @Test fun staleNonceOrInstallerSessionCannotFinishCurrentRequest() {
        val record = submitted(sessionId = 45)
        install(version = 20, signer = signature)
        ledger.acceptStatus(
            callback(record, PackageInstaller.STATUS_SUCCESS).putExtra(
                ManagedInstallStatusReceiver.EXTRA_REQUEST_ID,
                "f".repeat(32),
            ),
        ) { AndroidApkVerifier(context).installed() }
        assertEquals(ManagedInstallState.submitted, ledger.read()!!.state)

        ledger.acceptStatus(
            callback(record, PackageInstaller.STATUS_SUCCESS).putExtra(
                PackageInstaller.EXTRA_SESSION_ID,
                46,
            ),
        ) { AndroidApkVerifier(context).installed() }
        assertEquals(ManagedInstallState.submitted, ledger.read()!!.state)

        ledger.acceptStatus(
            callback(record, PackageInstaller.STATUS_SUCCESS).putExtra(
                PackageInstaller.EXTRA_PACKAGE_NAME,
                "com.example.wrong",
            ),
        ) { AndroidApkVerifier(context).installed() }
        assertEquals(ManagedInstallState.submitted, ledger.read()!!.state)
    }

    @Test fun restartPublishesUnknownAndNeverCreatesAnotherDispatch() {
        submitted(sessionId = 47)
        val reopened = ManagedInstallLedger(context)
        val receipt = reopened.read()!!.publicReceipt()
        assertEquals("unknown", receipt["status"])
        assertNull(receipt["observedVersionCode"])
        try {
            reopened.recordSubmission(
                "caller-session-00000002",
                48,
                release(),
                "3".repeat(32),
            )
            fail("Restart must not resend an unresolved install")
        } catch (failure: UpdateFailure) {
            assertEquals("busy", failure.code)
        }
    }

    @Test fun terminalReceiptCannotBeDowngradedByALateCallback() {
        val record = submitted(sessionId = 49)
        install(version = 20, signer = signature)
        ledger.acceptStatus(callback(record, PackageInstaller.STATUS_SUCCESS)) {
            AndroidApkVerifier(context).installed()
        }
        assertEquals(ManagedInstallState.confirmed, ledger.read()!!.state)
        ledger.acceptStatus(callback(record, PackageInstaller.STATUS_FAILURE_ABORTED)) {
            error("A terminal receipt must not read or change package state")
        }
        ledger.recordCommitUncertain(record)
        ledger.recordPreCommitFailure(record)
        assertEquals(ManagedInstallState.confirmed, ledger.read()!!.state)
    }

    @Test fun preCommitFailureAllowsAnExplicitReplacementDispatch() {
        val failed = submitted(sessionId = 51)
        ledger.recordPreCommitFailure(failed)
        assertEquals(ManagedInstallState.failed, ledger.read()!!.state)

        val replacement = ledger.recordSubmission(
            "caller-session-00000002",
            52,
            release(),
            "5".repeat(32),
        )
        assertEquals(ManagedInstallState.submitted, replacement.state)
        assertEquals("5".repeat(32), ledger.read()!!.requestId)
    }

    @Test fun uncertainCommitSurvivesRestartAndBlocksAnotherDispatch() {
        val record = submitted(sessionId = 53)
        ledger.recordCommitUncertain(record)
        val reopened = ManagedInstallLedger(context)
        val receipt = reopened.publicReceipt()!!
        assertEquals("unknown", receipt["status"])
        assertEquals(record.requestId, receipt["requestId"])
        assertEquals(record.installerSessionId, receipt["installerSessionId"])

        try {
            reopened.recordSubmission(
                "caller-session-00000002",
                54,
                release(),
                "6".repeat(32),
            )
            fail("An ambiguous commit must never permit a second dispatch")
        } catch (failure: UpdateFailure) {
            assertEquals("busy", failure.code)
        }
    }

    @Test fun corruptPrivateRecordFailsClosedBeforeAnotherDispatch() {
        context.getSharedPreferences("managed_client_install_v2", Context.MODE_PRIVATE)
            .edit().putInt("schemaVersion", 2).commit()
        try {
            ledger.recordSubmission(
                "caller-session-00000002",
                50,
                release(),
                "4".repeat(32),
            )
            fail("Corrupt private state must not permit a duplicate dispatch")
        } catch (failure: UpdateFailure) {
            assertEquals("busy", failure.code)
        }
    }

    private fun submitted(
        sessionId: Int,
        requestId: String = "1".repeat(32),
    ) = ledger.recordSubmission(
        "caller-session-00000001",
        sessionId,
        release(),
        requestId,
        1_800_000_000_000,
    )

    private fun release() = ClientRelease(
        ClientRelease.APPLICATION_ID,
        20,
        "2.0",
        certificate,
        "b".repeat(64),
        100,
        26,
        "/api/v1/client/releases/20/apk",
    )

    private fun callback(record: ManagedInstallRecord, status: Int) = Intent(
        ManagedInstallStatusReceiver.ACTION,
    ).putExtra(ManagedInstallStatusReceiver.EXTRA_REQUEST_ID, record.requestId)
        .putExtra(PackageInstaller.EXTRA_SESSION_ID, record.installerSessionId)
        .putExtra(PackageInstaller.EXTRA_PACKAGE_NAME, record.applicationId)
        .putExtra(PackageInstaller.EXTRA_STATUS, status)

    private fun install(version: Long, signer: Signature) {
        val signing = SigningInfo()
        shadowOf(signing).setSignatures(arrayOf(signer))
        val info = PackageInfo().apply {
            packageName = ClientRelease.APPLICATION_ID
            longVersionCode = version
            versionName = "$version"
            signingInfo = signing
        }
        shadowOf(context.packageManager).installPackage(info)
    }
}
