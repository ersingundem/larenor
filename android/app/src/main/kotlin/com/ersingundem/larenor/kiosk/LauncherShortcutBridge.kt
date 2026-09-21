package com.ersingundem.larenor.kiosk

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Closed, one-shot launcher navigation. It never accepts a route or URL. */
class LauncherShortcutBridge(
    activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private var pending = LauncherShortcutContract.parse(activity.intent?.action)
    private var sink: EventChannel.EventSink? = null
    private var resumed = false
    private var disposed = false

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun setResumed(value: Boolean) {
        resumed = value
    }

    fun handleIntent(intent: Intent) {
        if (disposed) return
        val action = LauncherShortcutContract.parse(intent.action) ?: return
        val target = sink
        if (resumed && target != null) {
            target.success(action)
        } else {
            // One bounded pending launch; a newer user launch replaces an old one.
            pending = action
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("unavailable", "Launcher shortcut unavailable", null)
            return
        }
        if (call.method != "takeInitial") {
            result.notImplemented()
            return
        }
        if (call.arguments != null) {
            result.error("invalid", "Launcher shortcut unavailable", null)
            return
        }
        if (!resumed) {
            result.success(null)
            return
        }
        val value = pending
        pending = null
        result.success(value)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        if (disposed || arguments != null || sink != null) {
            eventSink.error("busy", "Launcher shortcut unavailable", null)
            return
        }
        sink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun dispose() {
        disposed = true
        resumed = false
        pending = null
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    companion object {
        const val METHODS = "com.ersingundem.larenor/launcher_shortcuts"
        const val EVENTS = "com.ersingundem.larenor/launcher_shortcut_events"
    }
}
