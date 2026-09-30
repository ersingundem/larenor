package com.ersingundem.larenor.notifications

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom

/** Flutter notification bridge plus explicit native background-delivery provisioning. */
class LocalNotificationBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        const val METHODS = "com.ersingundem.larenor/local_notifications"
        const val EVENTS = "com.ersingundem.larenor/local_notification_taps"
        const val REQUEST_NOTIFICATIONS = 41054
        const val CHANNEL_VERSION = LocalNotificationRenderer.CHANNEL_VERSION
        const val CHANNEL_ID = LocalNotificationRenderer.CHANNEL_ID
        const val TAP_ACTION = LocalNotificationRenderer.TAP_ACTION
        private val HEX_32 = LocalNotificationRenderer.HEX_32
        private val HEX_64 = LocalNotificationRenderer.HEX_64
    }

    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val store = activity.getSharedPreferences(LocalNotificationRenderer.PLATFORM_STORE, Context.MODE_PRIVATE)
    private val renderer = LocalNotificationRenderer(activity)
    private val deliveryStore = LocalNotificationDeliveryStore(activity)
    private val random = SecureRandom()
    private var sink: EventChannel.EventSink? = null
    private var pendingTap: Map<String, Any>? = null
    private var resumed = false
    private var disposed = false
    private var permissionResult: MethodChannel.Result? = null

    init {
        renderer.createChannel()
        // WorkManager survives process death/reboot. Re-enqueueing by unique
        // name also migrates an already active lease from the former service.
        deliveryStore.load()?.takeIf { it.active }?.let {
            LocalNotificationDeliveryWork.schedule(activity, it, deliveryStore)
        }
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
        // Android's permission dialog temporarily owns window focus. Losing
        // focus alone must not retire the exact pending system callback.
        if (disposed || activity.isFinishing) cancelPermission("cancelled")
    }

    private fun permission(): String = when {
        Build.VERSION.SDK_INT < 33 -> "granted"
        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED -> "granted"
        store.getBoolean("permission_requested", false) -> "denied"
        else -> "notRequested"
    }

    private fun status(): Map<String, Any?> {
        val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        val hadSealedRecord = deliveryStore.hasSealedRecord()
        val delivery = deliveryStore.load()
        if (hadSealedRecord && delivery == null) {
            LocalNotificationDeliveryWork.markRecovery(activity, "deliveryStateUnavailable")
        }
        val recoveryRequired = store.getBoolean("recovery_required", false)
        val storedReason = store.getString("recovery_reason", null)
        val recoveryReason = if (!recoveryRequired) null else storedReason
            ?.takeIf(LocalNotificationDeliveryWork.RECOVERY_REASONS::contains)
            ?: "deliveryStateUnavailable"
        return mapOf(
            "schemaVersion" to 2,
            "supported" to true,
            "permission" to permission(),
            "channelVersion" to CHANNEL_VERSION,
            "channelEnabled" to (manager.areNotificationsEnabled() &&
                (Build.VERSION.SDK_INT < 26 ||
                    manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE)),
            "bindingId" to store.getString("binding_id", null),
            "subscriptionRevision" to store.getLong("subscription_revision", 0L),
            "lastSequence" to store.getLong("last_sequence", 0L),
            "batteryOptimizationExempt" to power.isIgnoringBatteryOptimizations(activity.packageName),
            "deliveryMode" to if (delivery == null) "foregroundPull" else "backgroundLease",
            "backgroundDelivery" to delivery?.let {
                mapOf(
                    "state" to it.phase,
                    "leaseId" to it.leaseId,
                    "leaseRevision" to it.leaseRevision,
                    "subscriptionRevision" to it.subscriptionRevision,
                    "credentialFingerprint" to it.credentialFingerprint,
                    "expiresAt" to it.expiresAt,
                )
            },
            "recovery" to mapOf("required" to recoveryRequired, "reason" to recoveryReason),
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
                "prepareBackgroundDelivery" -> {
                    require(foreground && permission() == "granted" && renderer.canNotify())
                    result.success(prepareBackgroundDelivery(exactMap(call.arguments, setOf(
                        "schemaVersion", "baseUrl", "coreId", "homeId", "bindingId", "subscriptionId",
                        "subscriptionRevision", "expiresAt",
                    ))))
                }
                "activateBackgroundDelivery" -> {
                    require(foreground && permission() == "granted" && renderer.canNotify())
                    result.success(activateBackgroundDelivery(exactMap(call.arguments, setOf(
                        "schemaVersion", "leaseId", "leaseRevision", "subscriptionRevision",
                        "credentialFingerprint", "expiresAt",
                    ))))
                }
                "disableBackgroundDelivery" -> {
                    require(foreground)
                    disableBackgroundDelivery(exactMap(call.arguments, setOf(
                        "schemaVersion", "leaseId", "expectedLeaseRevision",
                    )))
                    result.success(null)
                }
                "cancelPreparedBackgroundDelivery" -> {
                    require(foreground)
                    cancelPreparedBackgroundDelivery(exactMap(call.arguments, setOf(
                        "schemaVersion", "leaseId", "credentialFingerprint", "expectedSubscriptionRevision",
                    )))
                    result.success(null)
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
        if (!exact || disposed || activity.isFinishing) fail(result, "cancelled") else result.success(status())
        return true
    }

    private fun bind(value: Map<*, *>) {
        require(value["schemaVersion"] == 1)
        val binding = text(value["bindingId"], HEX_64)
        val subscription = text(value["subscriptionId"], HEX_32)
        val revision = positive(value["subscriptionRevision"])
        var stopDelivery = false
        synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
            val oldBinding = store.getString("binding_id", null)
            val oldSubscription = store.getString("subscription_id", null)
            val oldRevision = store.getLong("subscription_revision", 0L)
            if (oldBinding == binding && oldSubscription == subscription && revision < oldRevision) {
                throw NotificationRejected("stale")
            }
            if (oldBinding != binding || oldSubscription != subscription) {
                deliveryStore.clear()
                renderer.clearPostedNotifications(resetWatermark = true)
                store.edit().clear().putBoolean("permission_requested", permission() != "notRequested").apply()
                stopDelivery = true
            }
            store.edit()
                .putString("binding_id", binding)
                .putString("subscription_id", subscription)
                .putLong("subscription_revision", revision)
                .putBoolean("recovery_required", false)
                .apply()
        }
        if (stopDelivery) LocalNotificationDeliveryWork.stop(activity)
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
        require(raw is List<*> && raw.size <= LocalNotificationRenderer.MAX_BATCH)
        var previous = 0L
        val parsed = raw.map {
            renderer.parseFlutterEvent(
                exactMap(it, setOf("schemaVersion", "id", "sequence", "sensitivity", "title", "body", "redacted")),
            )
        }
        for (event in parsed) {
            if (event.sequence <= previous) throw NotificationRejected("outOfOrder")
            previous = event.sequence
        }
        synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
            renderer.reconcile(binding, revision, parsed)
        }
    }

    private fun prepareBackgroundDelivery(value: Map<*, *>): Map<String, Any> {
        require(value["schemaVersion"] == 1)
        val baseUrl = LocalNotificationDeliveryTransport.validateBaseUrl(value["baseUrl"] as? String
            ?: throw IllegalArgumentException())
        val coreId = text(value["coreId"], HEX_32)
        val homeId = text(value["homeId"], HEX_32)
        val bindingId = text(value["bindingId"], HEX_64)
        val subscriptionId = text(value["subscriptionId"], HEX_32)
        val subscriptionRevision = positive(value["subscriptionRevision"])
        val expiresAt = finitePositive(value["expiresAt"])
        val now = System.currentTimeMillis() / 1000.0
        require(expiresAt >= now + 60 && expiresAt <= now + 30 * 24 * 60 * 60)
        return synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
            if (bindingId != store.getString("binding_id", null) ||
                subscriptionId != store.getString("subscription_id", null) ||
                subscriptionRevision != store.getLong("subscription_revision", 0L)
            ) throw NotificationRejected("stale")

            deliveryStore.load()?.let { existing ->
                if (existing.phase == "pending" && existing.expiresAt <= now) {
                    if (!deliveryStore.clearPending(
                            existing.leaseId, existing.credentialFingerprint, existing.subscriptionRevision,
                        )
                    ) throw NotificationRejected("busy")
                } else if (existing.phase != "pending" || existing.baseUrl != baseUrl ||
                    existing.coreId != coreId || existing.homeId != homeId ||
                    existing.bindingId != bindingId || existing.subscriptionId != subscriptionId ||
                    existing.subscriptionRevision != subscriptionRevision
                ) {
                    throw NotificationRejected("busy")
                } else {
                    return@synchronized deliveryRegistration(existing)
                }
            }

            val credentialBytes = ByteArray(32).also(random::nextBytes)
            val credential = Base64.encodeToString(
                credentialBytes,
                Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
            )
            val fingerprint = MessageDigest.getInstance("SHA-256").digest(credentialBytes)
                .joinToString("") { "%02x".format(it) }
            val leaseId = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
            val pending = LocalNotificationDeliveryRecord(
                phase = "pending",
                baseUrl = baseUrl,
                coreId = coreId,
                homeId = homeId,
                bindingId = bindingId,
                subscriptionId = subscriptionId,
                subscriptionRevision = subscriptionRevision,
                leaseId = leaseId,
                leaseRevision = 0,
                credential = credential,
                credentialFingerprint = fingerprint,
                expiresAt = expiresAt,
                cursor = store.getLong("last_sequence", 0L),
            )
            deliveryStore.save(pending)
            deliveryRegistration(pending)
        }
    }

    private fun deliveryRegistration(record: LocalNotificationDeliveryRecord): Map<String, Any> = mapOf(
            "schemaVersion" to 1,
            "leaseId" to record.leaseId,
            "credential" to record.credential,
            "credentialFingerprint" to record.credentialFingerprint,
            "expectedSubscriptionRevision" to record.subscriptionRevision,
            "expiresAt" to record.expiresAt,
        )

    private fun activateBackgroundDelivery(value: Map<*, *>): Map<String, Any> {
        require(value["schemaVersion"] == 1)
        val leaseId = text(value["leaseId"], HEX_32)
        val leaseRevision = positive(value["leaseRevision"])
        val subscriptionRevision = positive(value["subscriptionRevision"])
        val fingerprint = text(value["credentialFingerprint"], HEX_64)
        val expiresAt = finitePositive(value["expiresAt"])
        val now = System.currentTimeMillis() / 1000.0
        val active = synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
            val pending = deliveryStore.load() ?: throw NotificationRejected("stale")
            if (pending.active && pending.leaseId == leaseId &&
                pending.credentialFingerprint == fingerprint
            ) {
                if (subscriptionRevision < pending.subscriptionRevision ||
                    subscriptionRevision != store.getLong("subscription_revision", 0L) ||
                    leaseRevision < pending.leaseRevision ||
                    leaseRevision == pending.leaseRevision &&
                        (pending.expiresAt != expiresAt || pending.subscriptionRevision != subscriptionRevision) ||
                    expiresAt < now + 60 || expiresAt > now + 30 * 24 * 60 * 60
                ) throw NotificationRejected("stale")
                pending.copy(
                    leaseRevision = leaseRevision,
                    subscriptionRevision = subscriptionRevision,
                    expiresAt = expiresAt,
                ).also { if (it != pending) deliveryStore.save(it) }
            } else {
                if (pending.phase != "pending" || pending.leaseId != leaseId ||
                    pending.credentialFingerprint != fingerprint ||
                    pending.subscriptionRevision != subscriptionRevision || expiresAt <= now ||
                    expiresAt > pending.expiresAt
                ) throw NotificationRejected("stale")
                pending.copy(
                    phase = "active",
                    leaseRevision = leaseRevision,
                    expiresAt = expiresAt,
                ).also(deliveryStore::save)
            }
        }
        LocalNotificationDeliveryWork.clearRecovery(activity)
        if (!LocalNotificationDeliveryWork.schedule(activity, active, deliveryStore)) {
            throw NotificationRejected("unavailable")
        }
        return deliveryActivation(active)
    }

    private fun deliveryActivation(record: LocalNotificationDeliveryRecord): Map<String, Any> = mapOf(
            "schemaVersion" to 1,
            "state" to "active",
            "leaseId" to record.leaseId,
            "leaseRevision" to record.leaseRevision,
            "expiresAt" to record.expiresAt,
        )

    private fun disableBackgroundDelivery(value: Map<*, *>) {
        require(value["schemaVersion"] == 1)
        val leaseId = text(value["leaseId"], HEX_32)
        val expectedRevision = positive(value["expectedLeaseRevision"])
        synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
            val record = deliveryStore.load()
            if (record == null && leaseId == store.getString("revoked_delivery_lease_id", null) &&
                expectedRevision == store.getLong("revoked_delivery_lease_revision", 0L)
            ) return@synchronized
            record ?: throw NotificationRejected("stale")
            if (!record.active || record.leaseId != leaseId || record.leaseRevision != expectedRevision) {
                throw NotificationRejected("stale")
            }
            if (!store.edit().putString("revoked_delivery_lease_id", leaseId)
                    .putLong("revoked_delivery_lease_revision", expectedRevision).commit()
            ) throw NotificationRejected("unavailable")
            if (!deliveryStore.clearIf(leaseId, expectedRevision)) throw NotificationRejected("stale")
            renderer.clearPostedNotifications()
        }
        LocalNotificationDeliveryWork.stop(activity)
        LocalNotificationDeliveryWork.clearRecovery(activity)
    }

    private fun cancelPreparedBackgroundDelivery(value: Map<*, *>) {
        require(value["schemaVersion"] == 1)
        val leaseId = text(value["leaseId"], HEX_32)
        val fingerprint = text(value["credentialFingerprint"], HEX_64)
        val subscriptionRevision = positive(value["expectedSubscriptionRevision"])
        synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
            val pending = deliveryStore.load()
            if (pending?.phase == "pending" && pending.leaseId == leaseId &&
                pending.credentialFingerprint == fingerprint &&
                pending.subscriptionRevision == subscriptionRevision
            ) {
                if (!store.edit().putString("cancelled_delivery_lease_id", leaseId)
                        .putString("cancelled_delivery_credential_fingerprint", fingerprint)
                        .putLong("cancelled_delivery_subscription_revision", subscriptionRevision)
                        .commit()
                ) throw NotificationRejected("unavailable")
                if (!deliveryStore.clearPending(leaseId, fingerprint, subscriptionRevision)) {
                    throw NotificationRejected("stale")
                }
                LocalNotificationDeliveryWork.clearRecovery(activity)
                return
            }
            if (pending == null &&
                leaseId == store.getString("cancelled_delivery_lease_id", null) &&
                fingerprint == store.getString("cancelled_delivery_credential_fingerprint", null) &&
                subscriptionRevision == store.getLong("cancelled_delivery_subscription_revision", 0L)
            ) return
            throw NotificationRejected("stale")
        }
    }

    fun handleIntent(intent: Intent?): Boolean {
        val tap = renderer.consumeTap(intent) ?: return false
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
    private fun finitePositive(value: Any?): Double = (value as? Number)?.toDouble()
        ?.takeIf { it.isFinite() && it > 0 } ?: throw IllegalArgumentException()
}
