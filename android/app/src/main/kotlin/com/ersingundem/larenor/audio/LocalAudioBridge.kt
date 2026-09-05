package com.ersingundem.larenor.audio

import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.media3.common.util.UnstableApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

@UnstableApi
class LocalAudioBridge(private val activity: Activity, messenger: BinaryMessenger) : AudioCommandHost {
    companion object {
        const val METHODS = "com.ersingundem.larenor/local_audio"
        const val EVENTS = "com.ersingundem.larenor/local_audio_events"
    }
    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private val router = AudioCommandRouter(this)
    private var sink: EventChannel.EventSink? = null
    private var removeObserver: (() -> Unit)? = null
    private var resumed = false
    private val handler = Handler(Looper.getMainLooper())
    private var disposed = false
    override val foreground get() = resumed && !disposed && !activity.isFinishing
    override val coordinator get() = LocalAudioRuntime.coordinator
    private val ticker = object : Runnable {
        override fun run() {
            if (!foreground || sink == null) return
            coordinator.refreshSnapshot()
        }
    }

    init {
        methods.setMethodCallHandler { call, result ->
            try {
                result.success(router.call(call.method, call.arguments))
            } catch (error: AudioRejected) {
                result.error(error.code, "Local audio operation unavailable", null)
            } catch (_: Exception) {
                result.error("unavailable", "Local audio operation unavailable", null)
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                sink = eventSink
                subscribe()
            }
            override fun onCancel(arguments: Any?) { sink = null; unsubscribe() }
        })
    }

    fun setResumed(value: Boolean) {
        resumed = value
        LocalAudioRuntime.setForeground(this, foreground)
        if (!foreground) {
            coordinator.cancelPending()
            unsubscribe()
        } else subscribe()
    }

    private fun subscribe() {
        if (removeObserver != null || sink == null || !foreground) return
        removeObserver = coordinator.observe {
            sink?.success(it.toMap())
            handler.removeCallbacks(ticker)
            if (it.isPlaying && foreground) handler.postDelayed(ticker, 1000)
        }
        coordinator.refreshSnapshot()
    }
    private fun unsubscribe() {
        removeObserver?.invoke()
        removeObserver = null
        handler.removeCallbacksAndMessages(null)
    }

    override fun start(ticket: String) {
        if (!foreground) throw AudioRejected("foregroundRequired")
        val intent = Intent(activity, LocalAudioService::class.java)
            .setAction(LocalAudioService.ACTION_PLAY)
            .putExtra(LocalAudioService.EXTRA_TICKET, ticket)
        if (activity.startService(intent) == null) throw AudioRejected("unavailable")
    }

    override fun powerStatus(): Map<String, Any?> {
        val notifications = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return mapOf(
            "supported" to true,
            "sdkInt" to Build.VERSION.SDK_INT,
            "notificationsEnabled" to if (Build.VERSION.SDK_INT >= 24) notifications.areNotificationsEnabled() else true,
            "notificationPermissionGranted" to (Build.VERSION.SDK_INT < 33 ||
                activity.checkSelfPermission("android.permission.POST_NOTIFICATIONS") == PackageManager.PERMISSION_GRANTED),
            "mediaNotificationExempt" to true,
            "batteryOptimizationExempt" to power.isIgnoringBatteryOptimizations(activity.packageName),
            "backgroundRestricted" to if (Build.VERSION.SDK_INT >= 28) manager.isBackgroundRestricted else false,
        )
    }

    override fun openSettings(notification: Boolean): Boolean {
        if (!foreground) throw AudioRejected("foregroundRequired")
        val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${activity.packageName}"))
        val preferred = if (notification && Build.VERSION.SDK_INT >= 26) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        } else if (!notification) {
            Intent("android.settings.VIEW_ADVANCED_POWER_USAGE_DETAIL",
                Uri.parse("package:${activity.packageName}"))
        } else details
        // No global Doze screen or exemption request; OEMs may expose only app info.
        for (intent in listOf(preferred, details)) {
            try { activity.startActivity(intent); return true } catch (_: Exception) { /* Try app info. */ }
        }
        return false
    }

    fun dispose() {
        disposed = true
        setResumed(false)
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        // Detaching a Flutter engine does not stop an existing real playback service.
    }
}
