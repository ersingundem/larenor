package com.ersingundem.larenor.updater

import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import java.io.File

internal class ManagedClientInstaller(private val context: Context) {
    private val policy = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
    private val ledger = ManagedInstallLedger(context)

    fun available(): Boolean = policy.isDeviceOwnerApp(context.packageName)

    fun submit(file: File, release: ClientRelease, callerSessionId: String): ManagedInstallRecord {
        if (!available()) throw UpdateFailure("permission")
        ledger.requireDispatchAvailable()
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(ClientRelease.APPLICATION_ID)
            setSize(release.sizeBytes)
            if (Build.VERSION.SDK_INT >= 31) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val sessionId = installer.createSession(params)
        val record = try {
            ledger.recordSubmission(callerSessionId, sessionId, release)
        } catch (failure: Exception) {
            runCatching { installer.abandonSession(sessionId) }
            throw failure
        }
        var commitAttempted = false
        try {
            installer.openSession(sessionId).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("base.apk", 0, release.sizeBytes).use { output ->
                        input.copyTo(output, 64 * 1024)
                        session.fsync(output)
                    }
                }
                val intent = Intent(context, ManagedInstallStatusReceiver::class.java).apply {
                    action = ManagedInstallStatusReceiver.ACTION
                    putExtra(ManagedInstallStatusReceiver.EXTRA_REQUEST_ID, record.requestId)
                }
                val sender = PendingIntent.getBroadcast(
                    context,
                    sessionId,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                ).intentSender
                // From this point an exception cannot prove that PackageInstaller
                // rejected the effect. A missing callback remains unknown and
                // blocks a second dispatch across process restart.
                commitAttempted = true
                session.commit(sender)
            }
            return record
        } catch (failure: Exception) {
            runCatching { installer.abandonSession(sessionId) }
            if (commitAttempted) {
                ledger.recordCommitUncertain(record)
            } else {
                ledger.recordPreCommitFailure(record)
            }
            throw UpdateFailure("unavailable")
        }
    }

    fun receipt(): Map<String, Any?>? = ledger.publicReceipt()
}

class ManagedInstallStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ManagedInstallLedger(context.applicationContext).acceptStatus(intent) {
            AndroidApkVerifier(context.applicationContext).installed()
        }
    }

    companion object {
        const val ACTION = "com.ersingundem.larenor.MANAGED_INSTALL_STATUS"
        const val EXTRA_REQUEST_ID = "requestId"
    }
}
