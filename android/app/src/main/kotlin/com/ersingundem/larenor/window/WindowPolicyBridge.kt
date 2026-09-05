package com.ersingundem.larenor.window

import android.app.Activity
import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import android.view.ViewTreeObserver
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Uses public per-window APIs; never replaces FlutterView's inset listener. */
class WindowPolicyBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, WindowPolicyHost {
    private val methods = MethodChannel(messenger, "com.ersingundem.larenor/window_policy")
    private val events = EventChannel(messenger, "com.ersingundem.larenor/window_policy_events")
    private val handler = Handler(Looper.getMainLooper())
    private val decor = activity.window.decorView
    private val controller = WindowPolicyController(this)
    private var resumed = false
    private var disposed = false
    private var sink: EventChannel.EventSink? = null
    private var lockAllowed: Boolean? = null
    private var lockState = "unknown"
    private val layoutObserver = ViewTreeObserver.OnGlobalLayoutListener {
        controller.refresh()
    }
    private var viewObserver: ViewTreeObserver? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        controller.onChanged = { sink?.success(it) }
        attachObserver()
    }

    private fun attachObserver() {
        val current = decor.viewTreeObserver
        if (current === viewObserver) return
        viewObserver?.takeIf { it.isAlive }?.removeOnGlobalLayoutListener(layoutObserver)
        current.addOnGlobalLayoutListener(layoutObserver)
        viewObserver = current
    }

    fun setResumed(value: Boolean) {
        resumed = value
        if (disposed) return
        attachObserver()
        refreshLockStatus()
        controller.refresh(force = true)
    }

    fun windowChanged() {
        if (disposed) return
        attachObserver()
        refreshLockStatus()
        controller.refresh(force = true)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("unavailable", "Window unavailable", null); return }
        try {
            when (call.method) {
                "snapshot" -> {
                    if (call.arguments != null) throw IllegalArgumentException()
                    refreshLockStatus()
                    result.success(controller.snapshot())
                }
                "setProfile" -> result.success(controller.setProfile(call.arguments))
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            result.error("invalidProfile", "Invalid window policy request", null)
        } catch (_: RuntimeException) {
            result.error("unavailable", "Window unavailable", null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        if (disposed) { events.endOfStream(); return }
        sink = events
        refreshLockStatus()
        events.success(controller.snapshot())
    }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun readEnvironment(): WindowEnvironment {
        val insets = ViewCompat.getRootWindowInsets(decor)
        val display = decor.display
        return WindowEnvironment(
            resumed = resumed,
            focused = decor.hasWindowFocus(),
            multiWindow = activity.isInMultiWindowMode,
            pictureInPicture = Build.VERSION.SDK_INT >= 26 && activity.isInPictureInPictureMode,
            externalDisplay = display != null && display.displayId != Display.DEFAULT_DISPLAY,
            displayKnown = display != null,
            desktopMode = activity.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_DESK,
            captionVisible = insets?.isVisible(WindowInsetsCompat.Type.captionBar()),
            imeVisible = insets?.isVisible(WindowInsetsCompat.Type.ime()),
            statusBarVisible = insets?.isVisible(WindowInsetsCompat.Type.statusBars()),
            navigationBarVisible = insets?.isVisible(WindowInsetsCompat.Type.navigationBars()),
            lockTaskPermitted = lockAllowed,
            lockTaskState = lockState,
        )
    }

    // Binder-backed management observations are refreshed on lifecycle or
    // explicit reads, never on every resize/layout frame.
    private fun refreshLockStatus() {
        val dpm = activity.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
        val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        lockAllowed = try { dpm?.isLockTaskPermitted(activity.packageName) }
            catch (_: RuntimeException) { null }
        lockState = try {
            when (am?.lockTaskModeState) {
                ActivityManager.LOCK_TASK_MODE_NONE -> "none"
                ActivityManager.LOCK_TASK_MODE_PINNED -> "pinned"
                ActivityManager.LOCK_TASK_MODE_LOCKED -> "locked"
                else -> "unknown"
            }
        } catch (_: RuntimeException) { "unknown" }
    }

    override fun setBarsHidden(hidden: Boolean) {
        val bars = WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars()
        val control = WindowCompat.getInsetsController(activity.window, decor)
        if (hidden) {
            control.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            control.hide(bars)
        } else {
            control.show(bars)
        }
    }
    override fun nowMillis(): Long = SystemClock.uptimeMillis()
    override fun schedule(delayMillis: Long, callback: () -> Unit): WindowCancellation {
        val work = Runnable { if (!disposed) callback() }
        handler.postDelayed(work, delayMillis.coerceAtLeast(0))
        return WindowCancellation { handler.removeCallbacks(work) }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        viewObserver?.takeIf { it.isAlive }?.removeOnGlobalLayoutListener(layoutObserver)
        viewObserver = null
        controller.dispose()
    }
}
