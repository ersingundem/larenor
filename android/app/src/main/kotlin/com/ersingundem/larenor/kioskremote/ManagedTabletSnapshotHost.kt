package com.ersingundem.larenor.kioskremote

import android.app.Activity
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.view.Display

enum class ManagedTabletNativeCommandResult { succeeded, denied, failed }

data class ManagedTabletNativeSnapshot(
    val batteryPercent: Int,
    val network: String,
    val appVersion: String,
    val appForeground: Boolean,
    val kioskState: String,
) {
    init {
        require(batteryPercent in 0..100)
        require(network in setOf("offline", "wifi", "ethernet", "cellular", "other"))
        require(appVersion.length in 1..64 && appVersion.matches(Regex("^[A-Za-z0-9._+() -]+$")))
        require(kioskState in setOf("none", "pinned", "locked", "unknown"))
    }

    fun toWire(): Map<String, Any> = mapOf(
        "schemaVersion" to 1,
        "batteryPercent" to batteryPercent,
        "network" to network,
        "appVersion" to appVersion,
        "appForeground" to appForeground,
        "kioskState" to kioskState,
    )
}

interface ManagedTabletSnapshotHost {
    fun read(appForeground: Boolean): ManagedTabletNativeSnapshot
    fun lockKiosk(): ManagedTabletNativeCommandResult
}

/** Reads bounded platform state and never reads Wi-Fi identity or credentials. */
class AndroidManagedTabletSnapshotHost(private val activity: Activity) : ManagedTabletSnapshotHost {
    override fun read(appForeground: Boolean): ManagedTabletNativeSnapshot = ManagedTabletNativeSnapshot(
        batteryPercent = batteryPercent(),
        network = networkKind(),
        appVersion = appVersion(),
        appForeground = appForeground,
        kioskState = kioskState(),
    )

    override fun lockKiosk(): ManagedTabletNativeCommandResult {
        val display = activity.window.decorView.display
        val desktop = activity.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK ==
            Configuration.UI_MODE_TYPE_DESK
        val eligible = activity.window.decorView.hasWindowFocus() &&
            display?.displayId == Display.DEFAULT_DISPLAY &&
            !activity.isInMultiWindowMode &&
            !activity.isInPictureInPictureMode &&
            !desktop
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (!eligible || keyguard?.isKeyguardLocked != false) {
            return ManagedTabletNativeCommandResult.denied
        }
        val policy = activity.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
            ?: return ManagedTabletNativeCommandResult.failed
        val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return ManagedTabletNativeCommandResult.failed
        return try {
            if (!policy.isLockTaskPermitted(activity.packageName)) {
                ManagedTabletNativeCommandResult.denied
            } else if (manager.lockTaskModeState == ActivityManager.LOCK_TASK_MODE_LOCKED) {
                ManagedTabletNativeCommandResult.succeeded
            } else if (manager.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE) {
                ManagedTabletNativeCommandResult.denied
            } else {
                activity.startLockTask()
                if (manager.lockTaskModeState == ActivityManager.LOCK_TASK_MODE_LOCKED) {
                    ManagedTabletNativeCommandResult.succeeded
                } else {
                    ManagedTabletNativeCommandResult.failed
                }
            }
        } catch (_: SecurityException) {
            ManagedTabletNativeCommandResult.denied
        } catch (_: RuntimeException) {
            ManagedTabletNativeCommandResult.failed
        }
    }

    private fun batteryPercent(): Int {
        val battery = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: throw IllegalStateException("battery_unavailable")
        val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0 || level > scale) throw IllegalStateException("battery_unavailable")
        return ((level.toLong() * 100L) / scale.toLong()).toInt().coerceIn(0, 100)
    }

    private fun networkKind(): String {
        val manager = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = manager.activeNetwork ?: return "offline"
        val capabilities = manager.getNetworkCapabilities(network) ?: return "offline"
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "other"
        }
    }

    @Suppress("DEPRECATION")
    private fun appVersion(): String {
        val value = activity.packageManager.getPackageInfo(activity.packageName, 0).versionName
        return value?.takeIf {
            it.length in 1..64 && it.matches(Regex("^[A-Za-z0-9._+() -]+$"))
        } ?: throw IllegalStateException("app_version_unavailable")
    }

    private fun kioskState(): String {
        val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return when (manager.lockTaskModeState) {
            ActivityManager.LOCK_TASK_MODE_NONE -> "none"
            ActivityManager.LOCK_TASK_MODE_PINNED -> "pinned"
            ActivityManager.LOCK_TASK_MODE_LOCKED -> "locked"
            else -> "unknown"
        }
    }
}
