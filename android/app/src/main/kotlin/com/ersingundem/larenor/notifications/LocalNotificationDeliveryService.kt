package com.ersingundem.larenor.notifications

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.ersingundem.larenor.MainActivity
import com.ersingundem.larenor.R
import java.lang.ref.WeakReference
import java.security.SecureRandom
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.math.min

internal object LocalNotificationDeliveryRuntime {
    val RECOVERY_REASONS = setOf(
        "serviceStartDenied", "bootStartDenied", "bootRecoveryRequired", "invalidStart",
        "deliveryUnavailable", "notificationPermissionRevoked", "deliveryStateUnavailable",
        "deliveryAuthorityRejected", "deliveryAuthorityChanged", "deliveryProtocolRejected",
    )
    val LIFECYCLE_LOCK = Any()
    @Volatile private var activityForeground = false
    @Volatile private var service = WeakReference<LocalNotificationDeliveryService>(null)

    fun setActivityForeground(value: Boolean) {
        activityForeground = value
        service.get()?.activityForegroundChanged(value)
    }

    fun isActivityForeground(): Boolean = activityForeground

    fun attach(value: LocalNotificationDeliveryService) {
        service = WeakReference(value)
    }

    fun detach(value: LocalNotificationDeliveryService) {
        if (service.get() === value) service.clear()
    }

    fun start(context: Context): Boolean = try {
        val intent = Intent(context.applicationContext, LocalNotificationDeliveryService::class.java)
            .setAction(LocalNotificationDeliveryService.ACTION_START)
        if (Build.VERSION.SDK_INT >= 26) context.applicationContext.startForegroundService(intent)
        else context.applicationContext.startService(intent)
        true
    } catch (_: Exception) {
        markRecovery(context, "serviceStartDenied")
        false
    }

    fun stop(context: Context) {
        context.applicationContext.stopService(
            Intent(context.applicationContext, LocalNotificationDeliveryService::class.java),
        )
    }

    fun markRecovery(context: Context, reason: String) {
        require(reason in RECOVERY_REASONS)
        context.applicationContext.getSharedPreferences(
            LocalNotificationRenderer.PLATFORM_STORE,
            Context.MODE_PRIVATE,
        ).edit().putBoolean("recovery_required", true).putString("recovery_reason", reason).commit()
    }

    fun clearRecovery(context: Context) {
        context.applicationContext.getSharedPreferences(
            LocalNotificationRenderer.PLATFORM_STORE,
            Context.MODE_PRIVATE,
        ).edit().putBoolean("recovery_required", false).remove("recovery_reason").commit()
    }
}

class LocalNotificationDeliveryService : Service() {
    companion object {
        const val ACTION_START = "com.ersingundem.larenor.LOCAL_NOTIFICATION_DELIVERY_START"
        private const val FOREGROUND_CHANNEL = "larenor_local_notification_delivery_v1"
        private const val FOREGROUND_ID = 0x4c4e4401
        private const val NORMAL_DELAY_SECONDS = 60L
        private const val MAX_BACKOFF_SECONDS = 900L
    }

    private val executor = ScheduledThreadPoolExecutor(1) { runnable ->
        Thread(runnable, "larenor-notification-delivery").apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true }
    private val random = SecureRandom()
    private lateinit var renderer: LocalNotificationRenderer
    private lateinit var deliveryStore: LocalNotificationDeliveryStore
    private lateinit var transport: LocalNotificationDeliveryTransport
    private var scheduled: ScheduledFuture<*>? = null
    private var failures = 0
    private var stopped = false
    private var generation = 0L

    override fun onCreate() {
        super.onCreate()
        renderer = LocalNotificationRenderer(this).also { it.createChannel() }
        deliveryStore = LocalNotificationDeliveryStore(this)
        transport = LocalNotificationDeliveryTransport()
        createForegroundChannel()
        val notification = foregroundNotification()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    FOREGROUND_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
                )
            } else {
                startForeground(FOREGROUND_ID, notification)
            }
        } catch (_: Exception) {
            stopped = true
            LocalNotificationDeliveryRuntime.markRecovery(this, "serviceStartDenied")
            executor.shutdownNow()
            stopSelf()
            return
        }
        LocalNotificationDeliveryRuntime.attach(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (stopped) return START_NOT_STICKY
        if (intent?.action != null && intent.action != ACTION_START) {
            retire("invalidStart", clearCredential = false)
            return START_NOT_STICKY
        }
        schedule(0)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    internal fun activityForegroundChanged(foreground: Boolean) {
        if (foreground) {
            synchronized(this) {
                generation += 1
                scheduled?.cancel(false)
                scheduled = null
            }
        } else {
            schedule(0)
        }
    }

    @Synchronized
    private fun schedule(delaySeconds: Long) {
        if (stopped || LocalNotificationDeliveryRuntime.isActivityForeground()) return
        scheduled?.cancel(false)
        generation += 1
        val expectedGeneration = generation
        scheduled = executor.schedule({ poll(expectedGeneration) }, delaySeconds, TimeUnit.SECONDS)
    }

    private fun poll(expectedGeneration: Long) {
        if (!isCurrent(expectedGeneration)) return
        val record = deliveryStore.load()
        if (!validRecord(record)) {
            retire(
                "deliveryUnavailable",
                clearCredential = invalidRecordRequiresClear(record),
                expectedRecord = record,
                expectedGeneration = expectedGeneration,
            )
            return
        }
        record ?: return
        if (!renderer.canNotify() || !foregroundChannelEnabled()) {
            retire(
                "notificationPermissionRevoked",
                clearCredential = false,
                expectedGeneration = expectedGeneration,
            )
            return
        }
        val result = transport.pull(record)
        if (!hasCurrentAuthority(expectedGeneration, record)) {
            scheduleIfBackground()
            return
        }
        when (result) {
            is DeliveryPullResult.Success -> {
                try {
                    var cursor = record.cursor
                    for (event in result.events) {
                        val accepted = withCurrentAuthority(expectedGeneration, record) {
                            renderer.post(record.bindingId, record.subscriptionRevision, event)
                            cursor = event.sequence
                            deliveryStore.updateCursor(record.leaseId, record.leaseRevision, cursor)
                        }
                        if (!accepted) {
                            scheduleIfBackground()
                            return
                        }
                    }
                    failures = 0
                    schedule(if (result.more && result.events.isNotEmpty()) 0 else NORMAL_DELAY_SECONDS)
                } catch (_: Exception) {
                    if (!hasCurrentAuthority(expectedGeneration, record)) {
                        scheduleIfBackground()
                    } else {
                        retire(
                            "deliveryStateUnavailable",
                            clearCredential = false,
                            expectedRecord = record,
                            expectedGeneration = expectedGeneration,
                        )
                    }
                }
            }
            DeliveryPullResult.AuthorityRejected -> retire(
                "deliveryAuthorityRejected",
                clearCredential = true,
                expectedRecord = record,
                expectedGeneration = expectedGeneration,
            )
            DeliveryPullResult.AuthorityChanged -> retire(
                "deliveryAuthorityChanged",
                clearCredential = false,
                expectedRecord = record,
                expectedGeneration = expectedGeneration,
            )
            DeliveryPullResult.ProtocolRejected -> retire(
                "deliveryProtocolRejected",
                clearCredential = false,
                expectedRecord = record,
                expectedGeneration = expectedGeneration,
            )
            DeliveryPullResult.TransientFailure -> {
                failures = min(failures + 1, 8)
                val base = min(MAX_BACKOFF_SECONDS, NORMAL_DELAY_SECONDS shl min(failures - 1, 4))
                val jitter = random.nextInt((base / 4 + 1).toInt()).toLong()
                schedule(min(MAX_BACKOFF_SECONDS, base + jitter))
            }
        }
    }

    @Synchronized
    private fun isCurrent(expectedGeneration: Long): Boolean =
        !stopped && generation == expectedGeneration && !LocalNotificationDeliveryRuntime.isActivityForeground()

    private fun scheduleIfBackground() {
        if (!LocalNotificationDeliveryRuntime.isActivityForeground()) schedule(0)
    }

    @Synchronized
    private fun hasCurrentAuthority(
        expectedGeneration: Long,
        record: LocalNotificationDeliveryRecord,
    ): Boolean = isCurrent(expectedGeneration) && validRecord(record) &&
        deliveryStore.matches(record.leaseId, record.leaseRevision)

    @Synchronized
    private fun withCurrentAuthority(
        expectedGeneration: Long,
        record: LocalNotificationDeliveryRecord,
        action: () -> Unit,
    ): Boolean {
        return synchronized(LocalNotificationDeliveryRuntime.LIFECYCLE_LOCK) {
            if (!hasCurrentAuthority(expectedGeneration, record)) return@synchronized false
            action()
            true
        }
    }

    private fun validRecord(record: LocalNotificationDeliveryRecord?): Boolean {
        if (record == null || !record.active || record.expiresAt <= System.currentTimeMillis() / 1000.0) return false
        val platform = getSharedPreferences(LocalNotificationRenderer.PLATFORM_STORE, Context.MODE_PRIVATE)
        return record.bindingId == platform.getString("binding_id", null) &&
            record.subscriptionId == platform.getString("subscription_id", null) &&
            record.subscriptionRevision == platform.getLong("subscription_revision", 0L)
    }

    private fun invalidRecordRequiresClear(record: LocalNotificationDeliveryRecord?): Boolean {
        if (record == null) return false
        if (record.expiresAt <= System.currentTimeMillis() / 1000.0) return true
        val platform = getSharedPreferences(LocalNotificationRenderer.PLATFORM_STORE, Context.MODE_PRIVATE)
        return record.bindingId != platform.getString("binding_id", null) ||
            record.subscriptionId != platform.getString("subscription_id", null)
    }

    private fun retire(
        reason: String,
        clearCredential: Boolean,
        expectedRecord: LocalNotificationDeliveryRecord? = null,
        expectedGeneration: Long? = null,
    ) {
        synchronized(this) {
            if (stopped) return
            if (expectedGeneration != null && !isCurrent(expectedGeneration)) return
            if (clearCredential) synchronized(LocalNotificationDeliveryRuntime.LIFECYCLE_LOCK) {
                if (expectedRecord != null &&
                    !deliveryStore.clearIf(expectedRecord.leaseId, expectedRecord.leaseRevision)
                ) {
                    scheduleIfBackground()
                    return
                }
                if (expectedRecord == null) runCatching { deliveryStore.clear() }
                renderer.clearPostedNotifications()
            }
            stopped = true
            generation += 1
            scheduled?.cancel(false)
            scheduled = null
            LocalNotificationDeliveryRuntime.markRecovery(this, reason)
            if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
        }
    }

    private fun createForegroundChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                FOREGROUND_CHANNEL,
                getString(R.string.local_notification_delivery_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.local_notification_delivery_channel_description)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }

    private fun foregroundChannelEnabled(): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(FOREGROUND_CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun foregroundNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            FOREGROUND_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, FOREGROUND_CHANNEL)
            .setSmallIcon(R.drawable.larenor_monochrome)
            .setContentTitle(getString(R.string.local_notification_delivery_title))
            .setContentText(getString(R.string.local_notification_delivery_text))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
    }

    override fun onDestroy() {
        stopped = true
        synchronized(this) {
            generation += 1
            scheduled?.cancel(true)
            scheduled = null
        }
        executor.shutdownNow()
        LocalNotificationDeliveryRuntime.detach(this)
        super.onDestroy()
    }
}
