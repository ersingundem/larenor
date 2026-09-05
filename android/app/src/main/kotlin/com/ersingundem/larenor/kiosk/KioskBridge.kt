package com.ersingundem.larenor.kiosk

import android.app.Activity
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.SystemClock
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class KioskBridge(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler, KioskHost {
    private val channel = MethodChannel(messenger, "com.ersingundem.larenor/kiosk")
    private val admin = ComponentName(activity, KioskAdminReceiver::class.java)
    private val policy = KioskPolicy(this)
    private var resumed = false
    private var disposed = false
    init { channel.setMethodCallHandler(this) }
    fun setResumed(value: Boolean) { resumed = value; if (!value) policy.invalidate() }
    fun windowChanged() { policy.invalidate() }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("unavailable", "Kiosk unavailable", null); return }
        try {
            val response = when (call.method) {
                "snapshot" -> { if (call.arguments != null) throw KioskFailure("invalid"); policy.snapshot() }
                "prepare" -> policy.prepare(call.arguments)
                "execute" -> policy.execute(call.arguments)
                "cancel" -> { policy.cancel(call.arguments); null }
                else -> { result.notImplemented(); return }
            }
            result.success(response)
        } catch (failure: KioskFailure) { result.error(failure.code, "Kiosk action unavailable", null) }
        catch (_: RuntimeException) { result.error("unavailable", "Kiosk unavailable", null) }
    }
    private fun dpm() = activity.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
    private fun <T> observed(block: () -> T): T? = try { block() } catch (_: RuntimeException) { null }
    override fun read(): KioskState {
        val manager = activity.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
        val owner = observed { manager?.isDeviceOwnerApp(activity.packageName) }
        val display = activity.window.decorView.display
        val desktop = activity.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_DESK
        val eligible = display != null && display.displayId == Display.DEFAULT_DISPLAY &&
            !activity.isInMultiWindowMode && !activity.isInPictureInPictureMode && !desktop
        val locked = observed { (activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked }
        val state = observed { (activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).lockTaskModeState }
        return KioskState(
            deviceOwner = owner,
            permitted = observed { manager?.isLockTaskPermitted(activity.packageName) },
            lockState = when (state) {
                ActivityManager.LOCK_TASK_MODE_NONE -> "none"
                ActivityManager.LOCK_TASK_MODE_PINNED -> "pinned"
                ActivityManager.LOCK_TASK_MODE_LOCKED -> "locked"
                else -> "unknown"
            },
            resumed = resumed, focused = activity.window.decorView.hasWindowFocus(), eligibleWindow = eligible,
            keyguardLocked = locked,
            powerMenuAllowed = if (owner == true && Build.VERSION.SDK_INT >= 28) observed {
                manager!!.getLockTaskFeatures(admin) and DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS != 0
            } else if (owner == true) true else null,
            allowlistCount = if (owner == true) observed { manager!!.getLockTaskPackages(admin).size } else null,
        )
    }
    override fun apply(action: KioskAction) {
        when (action) {
            KioskAction.allowApp -> {
                val manager = dpm()
                val existing = manager.getLockTaskPackages(admin)
                manager.setLockTaskPackages(admin, (existing.toList() + activity.packageName).distinct().toTypedArray())
            }
            KioskAction.removeApp -> {
                val manager = dpm()
                manager.setLockTaskPackages(admin, manager.getLockTaskPackages(admin).filter { it != activity.packageName }.toTypedArray())
            }
            KioskAction.restorePowerMenu -> {
                if (Build.VERSION.SDK_INT < 28) throw IllegalStateException()
                val manager = dpm()
                manager.setLockTaskFeatures(admin, manager.getLockTaskFeatures(admin) or DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS)
            }
            KioskAction.enter -> {
                // Android would otherwise fall back to user-removable screen pinning.
                if (!dpm().isLockTaskPermitted(activity.packageName)) throw SecurityException()
                activity.startLockTask()
            }
            KioskAction.exit -> activity.stopLockTask()
        }
    }
    override fun nowMillis(): Long = SystemClock.elapsedRealtime()
    override fun token(): String = UUID.randomUUID().toString()
    fun dispose() { disposed = true; policy.dispose(); channel.setMethodCallHandler(null) }
}
