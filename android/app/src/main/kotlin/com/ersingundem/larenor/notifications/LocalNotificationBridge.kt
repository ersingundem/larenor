package com.ersingundem.larenor.notifications

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import com.ersingundem.larenor.MainActivity
import com.ersingundem.larenor.R
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom

/** Native notification rendering only. Core authentication and polling stay in Flutter. */
class LocalNotificationBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        const val METHODS = "com.ersingundem.larenor/local_notifications"
        const val EVENTS = "com.ersingundem.larenor/local_notification_taps"
        const val REQUEST_NOTIFICATIONS = 41054
        const val CHANNEL_VERSION = 1
        const val CHANNEL_ID = "larenor_local_notifications_v1"
        const val TAP_ACTION = "com.ersingundem.larenor.LOCAL_NOTIFICATION_TAP"
        private const val STORE = "larenor_local_notification_platform_v1"
        private const val MAX_BATCH = 50
        private val HEX_32 = Regex("^[0-9a-f]{32}$")
        private val HEX_64 = Regex("^[0-9a-f]{64}$")
    }

    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val store = activity.getSharedPreferences(STORE, Context.MODE_PRIVATE)
    private val random = SecureRandom()
    private var sink: EventChannel.EventSink? = null
    private var pendingTap: Map<String, Any>? = null
    private var resumed = false
    private var disposed = false
    private var permissionResult: MethodChannel.Result? = null

    init {
        createChannel()
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        handleIntent(activity.intent)
    }

    val foreground: Boolean
        get() = resumed && !disposed && !activity.isFinishing && activity.window.decorView.hasWindowFocus()

    fun setResumed(value: Boolean) {
        resumed = value
        if (!value) cancelPermission("cancelled")
    }

    fun windowChanged() {
        if (!foreground) cancelPermission("cancelled")
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                activity.getString(R.string.local_notification_channel_name),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = activity.getString(R.string.local_notification_channel_description)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
        manager.notificationChannels
            .filter { it.id.startsWith("larenor_local_notifications_v") && it.id != CHANNEL_ID }
            .forEach { manager.deleteNotificationChannel(it.id) }
    }

    private fun permission(): String = when {
        Build.VERSION.SDK_INT < 33 -> "granted"
        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED -> "granted"
        store.getBoolean("permission_requested", false) -> "denied"
        else -> "notRequested"
    }

    private fun status(): Map<String, Any?> {
        val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "schemaVersion" to 1,
            "supported" to true,
            "permission" to permission(),
            "channelVersion" to CHANNEL_VERSION,
            "channelEnabled" to (manager.areNotificationsEnabled() &&
                (Build.VERSION.SDK_INT < 26 ||
                    manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE)),
            "bindingId" to store.getString("binding_id", null),
            "subscriptionRevision" to store.getLong("subscription_revision", 0L),
            "lastSequence" to store.getLong("last_sequence", 0L),
            "recoveryRequired" to store.getBoolean("recovery_required", false),
            "batteryOptimizationExempt" to power.isIgnoringBatteryOptimizations(activity.packageName),
            "deliveryMode" to "foregroundPull",
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return fail(result, "unavailable")
        try {
            when (call.method) {
                "probe" -> {
                    require(call.arguments == null)
                    result.success(status())
                }
                "requestPermission" -> requestPermission(call.arguments, result)
                "bind" -> {
                    require(foreground)
                    bind(exactMap(call.arguments, setOf("schemaVersion", "bindingId", "subscriptionId", "subscriptionRevision")))
                    result.success(status())
                }
                "reconcile" -> {
                    require(foreground && permission() == "granted")
                    reconcile(exactMap(call.arguments, setOf("schemaVersion", "bindingId", "subscriptionId", "subscriptionRevision", "events")))
                    result.success(status())
                }
                "openNotificationSettings" -> {
                    require(call.arguments == null && foreground)
                    openSettings(true)
                    result.success(null)
                }
                "openPowerSettings" -> {
                    require(call.arguments == null && foreground)
                    openSettings(false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: NotificationRejected) {
            fail(result, error.code)
        } catch (_: IllegalArgumentException) {
            fail(result, "invalidData")
        } catch (_: Exception) {
            fail(result, "unavailable")
        }
    }

    private fun requestPermission(arguments: Any?, result: MethodChannel.Result) {
        require(arguments == null && foreground)
        if (permissionResult != null) throw NotificationRejected("busy")
        if (permission() != "notRequested" || Build.VERSION.SDK_INT < 33) {
            result.success(status())
            return
        }
        store.edit().putBoolean("permission_requested", true).apply()
        permissionResult = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grants: IntArray): Boolean {
        if (requestCode != REQUEST_NOTIFICATIONS) return false
        val result = permissionResult ?: return true
        permissionResult = null
        val exact = permissions.size == 1 && permissions[0] == Manifest.permission.POST_NOTIFICATIONS && grants.size == 1
        if (!exact || disposed || !foreground) fail(result, "cancelled") else result.success(status())
        return true
    }

    private fun bind(value: Map<*, *>) {
        require(value["schemaVersion"] == 1)
        val binding = text(value["bindingId"], HEX_64)
        val subscription = text(value["subscriptionId"], HEX_32)
        val revision = positive(value["subscriptionRevision"])
        val oldBinding = store.getString("binding_id", null)
        val oldSubscription = store.getString("subscription_id", null)
        val oldRevision = store.getLong("subscription_revision", 0L)
        if (oldBinding == binding && oldSubscription == subscription && revision < oldRevision) {
            throw NotificationRejected("stale")
        }
        if (oldBinding != binding || oldSubscription != subscription) {
            storedNotificationIds().forEach(manager::cancel)
            store.edit().clear().putBoolean("permission_requested", permission() != "notRequested").apply()
        }
        store.edit()
            .putString("binding_id", binding)
            .putString("subscription_id", subscription)
            .putLong("subscription_revision", revision)
            .putBoolean("recovery_required", false)
            .apply()
    }

    private fun reconcile(value: Map<*, *>) {
        require(value["schemaVersion"] == 1)
        val binding = text(value["bindingId"], HEX_64)
        val subscription = text(value["subscriptionId"], HEX_32)
        val revision = positive(value["subscriptionRevision"])
        if (binding != store.getString("binding_id", null) ||
            subscription != store.getString("subscription_id", null) ||
            revision != store.getLong("subscription_revision", 0L)) throw NotificationRejected("stale")
        val raw = value["events"]
        require(raw is List<*> && raw.size <= MAX_BATCH)
        var previous = 0L
        val parsed = raw.map { parseEvent(exactMap(it, setOf("schemaVersion", "id", "sequence", "sensitivity", "title", "body", "redacted"))) }
        for (event in parsed) {
            if (event.sequence <= previous) throw NotificationRejected("outOfOrder")
            previous = event.sequence
        }
        var high = store.getLong("last_sequence", 0L)
        for (event in parsed) {
            if (event.sequence <= high) continue
            post(binding, revision, event)
            high = event.sequence
            store.edit().putLong("last_sequence", high).apply()
        }
    }

    private data class Event(val id: String, val sequence: Long, val title: String, val body: String, val private: Boolean)
    private fun parseEvent(value: Map<*, *>): Event {
        require(value["schemaVersion"] == 1)
        val id = text(value["id"], HEX_32)
        val sequence = positive(value["sequence"])
        val sensitivity = value["sensitivity"]
        require(sensitivity == "public" || sensitivity == "private")
        val title = bounded(value["title"], 120, false)
        val body = bounded(value["body"], 1024, true)
        val redacted = value["redacted"] as? Boolean ?: throw IllegalArgumentException()
        val private = sensitivity == "private"
        if (private != redacted || private && (title != "Larenor" || body.isNotEmpty())) {
            throw NotificationRejected("privacy")
        }
        return Event(id, sequence, title, body, private)
    }

    private fun post(binding: String, revision: Long, event: Event) {
        val nonce = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        val tapKey = "tap_${event.id}_${event.sequence}"
        val tapKeys = store.getStringSet("tap_keys", emptySet()).orEmpty().toMutableSet()
        while (tapKeys.size >= 64) tapKeys.firstOrNull()?.let { store.edit().remove(it).apply(); tapKeys.remove(it) }
        tapKeys.add(tapKey)
        val notificationId = event.id.hashCode()
        val notificationIds = storedNotificationIds().toMutableSet()
        notificationIds.add(notificationId)
        store.edit().putString(tapKey, nonce).putStringSet("tap_keys", tapKeys)
            .putStringSet("notification_ids", notificationIds.map(Int::toString).toSet()).apply()
        val intent = Intent(activity, MainActivity::class.java)
            .setAction(TAP_ACTION)
            .putExtra("bindingId", binding)
            .putExtra("subscriptionRevision", revision)
            .putExtra("eventId", event.id)
            .putExtra("sequence", event.sequence)
            .putExtra("nonce", nonce)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(
            activity,
            notificationId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val privateText = activity.getString(R.string.local_notification_private_preview)
        val notification = Notification.Builder(activity, CHANNEL_ID)
            .setSmallIcon(R.drawable.larenor_monochrome)
            .setContentTitle(event.title)
            .setContentText(if (event.private) privateText else event.body)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(if (event.private) Notification.VISIBILITY_PRIVATE else Notification.VISIBILITY_PUBLIC)
            .setPublicVersion(
                Notification.Builder(activity, CHANNEL_ID)
                    .setSmallIcon(R.drawable.larenor_monochrome)
                    .setContentTitle("Larenor")
                    .setContentText(privateText)
                    .setVisibility(Notification.VISIBILITY_PUBLIC)
                    .build(),
            )
            .build()
        manager.notify(notificationId, notification)
    }

    fun handleIntent(intent: Intent?): Boolean {
        if (intent?.action != TAP_ACTION) return false
        val binding = intent.getStringExtra("bindingId") ?: return false
        val event = intent.getStringExtra("eventId") ?: return false
        val sequence = intent.getLongExtra("sequence", 0L)
        val revision = intent.getLongExtra("subscriptionRevision", 0L)
        val nonce = intent.getStringExtra("nonce") ?: return false
        val key = "tap_${event}_${sequence}"
        val valid = HEX_64.matches(binding) && HEX_32.matches(event) && sequence > 0 && revision > 0 &&
            binding == store.getString("binding_id", null) && revision == store.getLong("subscription_revision", 0L) &&
            nonce == store.getString(key, null)
        intent.replaceExtras(null)
        intent.action = null
        if (!valid) return false
        val tapKeys = store.getStringSet("tap_keys", emptySet()).orEmpty().toMutableSet().apply { remove(key) }
        val notificationId = event.hashCode()
        val notificationIds = storedNotificationIds().toMutableSet().apply { remove(notificationId) }
        store.edit().remove(key).putStringSet("tap_keys", tapKeys)
            .putStringSet("notification_ids", notificationIds.map(Int::toString).toSet()).apply()
        manager.cancel(notificationId)
        val tap = mapOf("schemaVersion" to 1, "bindingId" to binding, "subscriptionRevision" to revision,
            "eventId" to event, "sequence" to sequence)
        if (sink == null) pendingTap = tap else sink?.success(tap)
        return true
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        if (arguments != null || sink != null) {
            eventSink.error("invalidData", "Notification tap unavailable", null)
            return
        }
        sink = eventSink
        pendingTap?.let { eventSink.success(it); pendingTap = null }
    }
    override fun onCancel(arguments: Any?) { sink = null }

    private fun openSettings(notification: Boolean) {
        val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))
        val preferred = if (notification && Build.VERSION.SDK_INT >= 26) {
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                .putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL_ID)
        } else if (!notification) {
            Intent("android.settings.VIEW_ADVANCED_POWER_USAGE_DETAIL", Uri.parse("package:${activity.packageName}"))
        } else details
        for (candidate in listOf(preferred, details)) {
            try { activity.startActivity(candidate); return } catch (_: Exception) { }
        }
        throw NotificationRejected("unavailable")
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        cancelPermission("cancelled")
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        pendingTap = null
    }
    private fun cancelPermission(code: String) {
        permissionResult?.let { fail(it, code) }
        permissionResult = null
    }
    private fun fail(result: MethodChannel.Result, code: String) = result.error(code, "Notification operation unavailable", null)
    private fun storedNotificationIds(): Set<Int> = store.getStringSet("notification_ids", emptySet())
        .orEmpty().mapNotNull(String::toIntOrNull).toSet()
    private fun exactMap(value: Any?, keys: Set<String>): Map<*, *> {
        require(value is Map<*, *> && value.keys == keys)
        return value
    }
    private fun text(value: Any?, pattern: Regex): String = (value as? String)?.takeIf(pattern::matches)
        ?: throw IllegalArgumentException()
    private fun positive(value: Any?): Long = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> throw IllegalArgumentException()
    }.takeIf { it in 1..Long.MAX_VALUE } ?: throw IllegalArgumentException()
    private fun bounded(value: Any?, maximum: Int, empty: Boolean): String {
        val text = value as? String ?: throw IllegalArgumentException()
        require(text.length <= maximum && (empty || text.isNotEmpty()) && text.none { it.code < 32 || it.code == 127 })
        return text
    }
}

private class NotificationRejected(val code: String) : RuntimeException()
