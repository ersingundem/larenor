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
import android.os.Process
import android.os.SystemClock
import android.view.Display
import androidx.core.content.pm.PackageInfoCompat

enum class ManagedTabletNativeCommandResult { succeeded, denied, failed }

data class ManagedTabletNativeSnapshot(
    val batteryPercent: Int,
    val charging: Boolean,
    val network: String,
    val appVersion: String,
    val appBuild: Int,
    val appForeground: Boolean,
    val kioskState: String,
    val memoryUsedMb: Int,
    val memoryLimitMb: Int,
    val processUptimeSeconds: Int,
) {
    init {
        require(batteryPercent in 0..100)
        require(network in setOf("offline", "wifi", "ethernet", "cellular", "other"))
        require(appVersion.length in 1..64 && appVersion.matches(Regex("^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$")))
        require(appBuild in 1..Int.MAX_VALUE)
        require(kioskState in setOf("none", "pinned", "locked", "unknown"))
        require(memoryUsedMb >= 0 && memoryLimitMb in 1..(1024 * 1024))
        require(memoryUsedMb <= memoryLimitMb)
        require(processUptimeSeconds >= 0)
    }

    fun toWire(): Map<String, Any> = mapOf(
        "schemaVersion" to 2,
        "batteryPercent" to batteryPercent,
        "charging" to charging,
        "network" to network,
        "appVersion" to appVersion,
        "appBuild" to appBuild,
        "appForeground" to appForeground,
        "kioskState" to kioskState,
        "memoryUsedMb" to memoryUsedMb,
        "memoryLimitMb" to memoryLimitMb,
        "processUptimeSeconds" to processUptimeSeconds,
    )
}

interface ManagedTabletSnapshotHost {
    fun read(appForeground: Boolean): ManagedTabletNativeSnapshot
    fun lockKiosk(): ManagedTabletNativeCommandResult
}

/** Reads bounded platform state and never reads Wi-Fi identity or credentials. */
class AndroidManagedTabletSnapshotHost(private val activity: Activity) : ManagedTabletSnapshotHost {
    override fun read(appForeground: Boolean): ManagedTabletNativeSnapshot {
        val battery = batteryState()
        val app = appIdentity()
        val memory = memoryState()
        return ManagedTabletNativeSnapshot(
            batteryPercent = battery.first,
            charging = battery.second,
            network = networkKind(),
            appVersion = app.first,
            appBuild = app.second,
            appForeground = appForeground,
            kioskState = kioskState(),
            memoryUsedMb = memory.first,
            memoryLimitMb = memory.second,
            processUptimeSeconds = processUptimeSeconds(),
        )
    }

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

    private fun batteryState(): Pair<Int, Boolean> {
        val battery = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: throw IllegalStateException("battery_unavailable")
        val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0 || level > scale) throw IllegalStateException("battery_unavailable")
        val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        if (status !in setOf(
                BatteryManager.BATTERY_STATUS_CHARGING,
                BatteryManager.BATTERY_STATUS_DISCHARGING,
                BatteryManager.BATTERY_STATUS_FULL,
                BatteryManager.BATTERY_STATUS_NOT_CHARGING,
                BatteryManager.BATTERY_STATUS_UNKNOWN,
            )
        ) throw IllegalStateException("battery_unavailable")
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        return Pair(
            ((level.toLong() * 100L) / scale.toLong()).toInt().coerceIn(0, 100),
            charging,
        )
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
    private fun appIdentity(): Pair<String, Int> {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        val version = info.versionName?.takeIf {
            it.length in 1..64 && it.matches(Regex("^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$"))
        } ?: throw IllegalStateException("app_version_unavailable")
        val build = PackageInfoCompat.getLongVersionCode(info)
        if (build !in 1..Int.MAX_VALUE.toLong()) {
            throw IllegalStateException("app_version_unavailable")
        }
        return Pair(version, build.toInt())
    }

    private fun memoryState(): Pair<Int, Int> {
        val runtime = Runtime.getRuntime()
        val usedBytes = (runtime.totalMemory() - runtime.freeMemory()).coerceAtLeast(0L)
        val limitBytes = runtime.maxMemory()
        if (limitBytes <= 0L || usedBytes > limitBytes) {
            throw IllegalStateException("memory_unavailable")
        }
        val unit = 1024L * 1024L
        val usedMb = (usedBytes / unit).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        val limitMb = ((limitBytes + unit - 1L) / unit)
            .coerceIn(1L, (1024L * 1024L))
            .toInt()
        if (usedMb > limitMb) throw IllegalStateException("memory_unavailable")
        return Pair(usedMb, limitMb)
    }

    private fun processUptimeSeconds(): Int {
        val elapsed = SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()
        if (elapsed < 0L) throw IllegalStateException("uptime_unavailable")
        return (elapsed / 1000L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
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
