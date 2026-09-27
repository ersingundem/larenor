package com.ersingundem.larenor.notifications

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.ersingundem.larenor.MainActivity
import com.ersingundem.larenor.R
import java.security.SecureRandom

internal class NotificationRejected(val code: String) : RuntimeException()

internal data class LocalNotificationRenderEvent(
    val id: String,
    val sequence: Long,
    val title: String,
    val body: String,
    val private: Boolean,
)

/** The single renderer used by foreground reconciliation and background delivery. */
internal class LocalNotificationRenderer(context: Context) {
    companion object {
        const val PLATFORM_STORE = "larenor_local_notification_platform_v1"
        const val CHANNEL_VERSION = 1
        const val CHANNEL_ID = "larenor_local_notifications_v1"
        const val TAP_ACTION = "com.ersingundem.larenor.LOCAL_NOTIFICATION_TAP"
        const val MAX_BATCH = 50
        val HEX_32 = Regex("^[0-9a-f]{32}$")
        val HEX_64 = Regex("^[0-9a-f]{64}$")

        private const val EVENT_NOTIFICATION_PREFIX = "notification_event_"
        private const val NEXT_NOTIFICATION_ID = "next_notification_id"
        private val lock = Any()
    }

    private val app = context.applicationContext
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val store = app.getSharedPreferences(PLATFORM_STORE, Context.MODE_PRIVATE)
    private val random = SecureRandom()

    fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                app.getString(R.string.local_notification_channel_name),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = app.getString(R.string.local_notification_channel_description)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
        manager.notificationChannels
            .filter { it.id.startsWith("larenor_local_notifications_v") && it.id != CHANNEL_ID }
            .forEach { manager.deleteNotificationChannel(it.id) }
    }

    fun canNotify(): Boolean =
        (Build.VERSION.SDK_INT < 33 ||
            app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            manager.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 26 ||
                manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE)

    fun parseFlutterEvent(value: Map<*, *>): LocalNotificationRenderEvent {
        require(value.keys == setOf("schemaVersion", "id", "sequence", "sensitivity", "title", "body", "redacted"))
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
        return LocalNotificationRenderEvent(id, sequence, title, body, private)
    }

    fun reconcile(
        binding: String,
        subscriptionRevision: Long,
        events: List<LocalNotificationRenderEvent>,
    ) = synchronized(lock) {
        var high = store.getLong("last_sequence", 0L)
        for (event in events) {
            if (event.sequence <= high) continue
            postLocked(binding, subscriptionRevision, event, advanceWatermark = true)
            high = event.sequence
        }
        val desiredEvents = events.map(LocalNotificationRenderEvent::id).toSet()
        val desired = desiredEvents.associateWith(::notificationIdForLocked)
        val staleMappings = storedEventNotificationIds().filterKeys { it !in desiredEvents }
        val staleIds = (storedNotificationIds() - desired.values.toSet()) + staleMappings.values
        staleIds.forEach(manager::cancel)
        val tapKeys = store.getStringSet("tap_keys", emptySet()).orEmpty()
        val retained = tapKeys.filter { tapKeyEventId(it) in desiredEvents }.toSet()
        val editor = store.edit()
        staleMappings.keys.forEach { editor.remove(EVENT_NOTIFICATION_PREFIX + it) }
        (tapKeys - retained).forEach(editor::remove)
        editor.putStringSet("tap_keys", retained).commit()
        store.edit().putStringSet("notification_ids", desired.values.map(Int::toString).toSet()).commit()
    }

    /** Posts once before returning; callers may then advance their own delivery cursor. */
    fun post(binding: String, subscriptionRevision: Long, event: LocalNotificationRenderEvent): Boolean =
        synchronized(lock) {
        if (event.sequence <= store.getLong("last_sequence", 0L)) return@synchronized false
        postLocked(binding, subscriptionRevision, event, advanceWatermark = true)
        true
    }

    private fun postLocked(
        binding: String,
        revision: Long,
        event: LocalNotificationRenderEvent,
        advanceWatermark: Boolean,
    ) {
        val nonce = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        val tapKey = "tap_${event.id}_${event.sequence}"
        val tapKeys = store.getStringSet("tap_keys", emptySet()).orEmpty().toMutableSet()
        while (tapKeys.size >= 64) {
            val oldest = tapKeys.minByOrNull(::tapKeySequence) ?: break
            dropTapKeyLocked(oldest)
            tapKeys.remove(oldest)
        }
        tapKeys.add(tapKey)
        val notificationId = notificationIdForLocked(event.id)
        val notificationIds = storedNotificationIds().toMutableSet().apply { add(notificationId) }
        if (!store.edit().putString(tapKey, nonce).putStringSet("tap_keys", tapKeys)
                .putStringSet("notification_ids", notificationIds.map(Int::toString).toSet()).commit()
        ) throw NotificationRejected("unavailable")

        val intent = Intent(app, MainActivity::class.java)
            .setAction(TAP_ACTION)
            .putExtra("bindingId", binding)
            .putExtra("subscriptionRevision", revision)
            .putExtra("eventId", event.id)
            .putExtra("sequence", event.sequence)
            .putExtra("nonce", nonce)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(
            app,
            notificationId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val privateText = app.getString(R.string.local_notification_private_preview)
        val notification = Notification.Builder(app, CHANNEL_ID)
            .setSmallIcon(R.drawable.larenor_monochrome)
            .setContentTitle(event.title)
            .setContentText(if (event.private) privateText else event.body)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(if (event.private) Notification.VISIBILITY_PRIVATE else Notification.VISIBILITY_PUBLIC)
            .setPublicVersion(
                Notification.Builder(app, CHANNEL_ID)
                    .setSmallIcon(R.drawable.larenor_monochrome)
                    .setContentTitle("Larenor")
                    .setContentText(privateText)
                    .setVisibility(Notification.VISIBILITY_PUBLIC)
                    .build(),
            )
            .build()
        manager.notify(notificationId, notification)
        if (advanceWatermark && !store.edit().putLong("last_sequence", event.sequence).commit()) {
            manager.cancel(notificationId)
            dropTapKeyLocked(tapKey)
            throw NotificationRejected("unavailable")
        }
    }

    fun consumeTap(intent: Intent?): Map<String, Any>? = synchronized(lock) {
        if (intent?.action != TAP_ACTION) return@synchronized null
        val binding = intent.getStringExtra("bindingId") ?: return@synchronized null
        val event = intent.getStringExtra("eventId") ?: return@synchronized null
        val sequence = intent.getLongExtra("sequence", 0L)
        val revision = intent.getLongExtra("subscriptionRevision", 0L)
        val nonce = intent.getStringExtra("nonce") ?: return@synchronized null
        val key = "tap_${event}_${sequence}"
        val valid = HEX_64.matches(binding) && HEX_32.matches(event) && sequence > 0 && revision > 0 &&
            binding == store.getString("binding_id", null) &&
            revision == store.getLong("subscription_revision", 0L) && nonce == store.getString(key, null)
        intent.replaceExtras(null)
        intent.action = null
        if (!valid) return@synchronized null
        val notificationId = storedEventNotificationIds()[event] ?: return@synchronized null
        val tapKeys = store.getStringSet("tap_keys", emptySet()).orEmpty().toMutableSet().apply { remove(key) }
        val notificationIds = storedNotificationIds().toMutableSet().apply { remove(notificationId) }
        val persisted = store.edit().remove(key).putStringSet("tap_keys", tapKeys)
            .remove(EVENT_NOTIFICATION_PREFIX + event)
            .putStringSet("notification_ids", notificationIds.map(Int::toString).toSet()).commit()
        if (!persisted) return@synchronized null
        manager.cancel(notificationId)
        mapOf(
            "schemaVersion" to 1,
            "bindingId" to binding,
            "subscriptionRevision" to revision,
            "eventId" to event,
            "sequence" to sequence,
        )
    }

    fun clearPostedNotifications(resetWatermark: Boolean = false) = synchronized(lock) {
        storedNotificationIds().forEach(manager::cancel)
        val editor = store.edit()
        storedEventNotificationIds().keys.forEach { editor.remove(EVENT_NOTIFICATION_PREFIX + it) }
        store.getStringSet("tap_keys", emptySet()).orEmpty().forEach(editor::remove)
        editor.remove("tap_keys").remove("notification_ids")
        if (resetWatermark) editor.remove("last_sequence")
        editor.commit()
    }

    private fun storedEventNotificationIds(): Map<String, Int> = store.all.entries.mapNotNull { (key, value) ->
        if (!key.startsWith(EVENT_NOTIFICATION_PREFIX)) return@mapNotNull null
        val eventId = key.removePrefix(EVENT_NOTIFICATION_PREFIX)
        val notificationId = value as? Int
        if (!HEX_32.matches(eventId) || notificationId == null || notificationId <= 0) null
        else eventId to notificationId
    }.toMap()

    private fun notificationIdForLocked(eventId: String): Int {
        require(HEX_32.matches(eventId))
        storedEventNotificationIds()[eventId]?.let { return it }
        val used = storedEventNotificationIds().values.toSet()
        var candidate = (store.all[NEXT_NOTIFICATION_ID] as? Int)?.takeIf { it > 0 } ?: 1
        repeat(128) {
            if (candidate !in used) {
                val next = if (candidate == Int.MAX_VALUE) 1 else candidate + 1
                if (!store.edit().putInt(EVENT_NOTIFICATION_PREFIX + eventId, candidate)
                        .putInt(NEXT_NOTIFICATION_ID, next).commit()
                ) throw NotificationRejected("unavailable")
                return candidate
            }
            candidate = if (candidate == Int.MAX_VALUE) 1 else candidate + 1
        }
        throw NotificationRejected("unavailable")
    }

    private fun storedNotificationIds(): Set<Int> = store.getStringSet("notification_ids", emptySet())
        .orEmpty().mapNotNull(String::toIntOrNull).toSet()

    private fun tapKeyEventId(key: String): String? = key.takeIf { it.startsWith("tap_") }
        ?.removePrefix("tap_")?.substringBefore('_')?.takeIf(HEX_32::matches)

    private fun tapKeySequence(key: String): Long = key.substringAfterLast('_').toLongOrNull() ?: Long.MAX_VALUE

    private fun dropTapKeyLocked(key: String) {
        val eventId = tapKeyEventId(key)
        val notificationId = eventId?.let { storedEventNotificationIds()[it] }
        val notificationIds = storedNotificationIds().toMutableSet()
        if (notificationId != null) {
            manager.cancel(notificationId)
            notificationIds.remove(notificationId)
        }
        store.edit().remove(key)
            .apply { if (eventId != null) remove(EVENT_NOTIFICATION_PREFIX + eventId) }
            .putStringSet("notification_ids", notificationIds.map(Int::toString).toSet())
            .commit()
    }

    private fun text(value: Any?, pattern: Regex): String = (value as? String)?.takeIf(pattern::matches)
        ?: throw IllegalArgumentException()

    private fun positive(value: Any?): Long = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> throw IllegalArgumentException()
    }.takeIf { it > 0 } ?: throw IllegalArgumentException()

    private fun bounded(value: Any?, maximum: Int, empty: Boolean): String {
        val text = value as? String ?: throw IllegalArgumentException()
        require(text.length <= maximum && (empty || text.isNotEmpty()) && text.none { it.code < 32 || it.code == 127 })
        return text
    }
}
