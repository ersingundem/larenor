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

    fun available(): Boolean = policy.isDeviceOwnerApp(context.packageName)

    fun submit(file: File, release: ClientRelease): Int {
        if (!available()) throw UpdateFailure("permission")
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(ClientRelease.APPLICATION_ID)
            setSize(release.sizeBytes)
            if (Build.VERSION.SDK_INT >= 31) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val sessionId = installer.createSession(params)
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
                    putExtra(ManagedInstallStatusReceiver.EXTRA_EXPECTED_VERSION, release.versionCode)
                }
                val sender = PendingIntent.getBroadcast(
                    context,
                    sessionId,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                ).intentSender
                session.commit(sender)
            }
            return sessionId
        } catch (failure: Exception) {
            runCatching { installer.abandonSession(sessionId) }
            throw UpdateFailure("unavailable")
        }
    }
}

class ManagedInstallStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val expectedVersion = intent.getLongExtra(EXTRA_EXPECTED_VERSION, -1)
        val safeStatus = when (status) {
            PackageInstaller.STATUS_SUCCESS -> "succeeded"
            PackageInstaller.STATUS_PENDING_USER_ACTION -> "denied"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "cancelled"
            else -> "failed"
        }
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString("status", safeStatus)
            .putInt("sessionId", sessionId)
            .putLong("expectedVersion", expectedVersion)
            .putLong("observedAt", System.currentTimeMillis())
            .apply()
    }

    companion object {
        const val ACTION = "com.ersingundem.larenor.MANAGED_INSTALL_STATUS"
        const val EXTRA_EXPECTED_VERSION = "expectedVersion"
        const val PREFERENCES = "managed_client_install"
    }
}
