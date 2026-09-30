package com.ersingundem.larenor.notifications

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequest
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.TimeUnit

/** Durable scheduler for delayed Android notification delivery. */
internal object LocalNotificationDeliveryWork {
    val LIFECYCLE_LOCK = Any()
    val RECOVERY_REASONS = setOf(
        "workScheduleUnavailable", "deliveryUnavailable", "notificationPermissionRevoked",
        "deliveryStateUnavailable", "deliveryAuthorityRejected", "deliveryAuthorityChanged",
        "deliveryLeaseRenewalRequired", "deliveryProtocolRejected",
    )

    const val TAG = "larenor-local-notification-delivery-v1"
    const val PERIODIC_NAME = "$TAG-periodic"
    const val IMMEDIATE_NAME = "$TAG-immediate"
    const val INPUT_CATCH_UP_DEPTH = "catchUpDepth"
    const val MAX_CATCH_UP_DEPTH = 2

    private val network = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    fun schedule(
        context: Context,
        expected: LocalNotificationDeliveryRecord,
        deliveryStore: LocalNotificationDeliveryStore,
        enqueue: ((PeriodicWorkRequest, OneTimeWorkRequest) -> List<ListenableFuture<*>>)? = null,
        cancel: (() -> Unit)? = null,
    ): Boolean = try {
        val work = if (enqueue == null || cancel == null) {
            WorkManager.getInstance(context.applicationContext)
        } else null
        val periodic = PeriodicWorkRequestBuilder<LocalNotificationDeliveryWorker>(15, TimeUnit.MINUTES)
            .setConstraints(network)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .addTag(TAG)
            .build()
        val immediate = OneTimeWorkRequestBuilder<LocalNotificationDeliveryWorker>()
            .setConstraints(network)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .setInputData(workDataOf(INPUT_CATCH_UP_DEPTH to 0))
            .addTag(TAG)
            .build()
        val cancelScheduled = cancel ?: {
            work!!.cancelAllWorkByTag(TAG)
            Unit
        }
        val results = enqueue?.invoke(periodic, immediate) ?: listOf(
            work!!.enqueueUniquePeriodicWork(
                PERIODIC_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                periodic,
            ).result,
            work.enqueueUniqueWork(
                IMMEDIATE_NAME,
                ExistingWorkPolicy.REPLACE,
                immediate,
            ).result,
        )
        require(results.size == 2)
        results.forEach { result ->
            result.addListener(
                {
                    try {
                        result.get()
                    } catch (_: Exception) {
                        scheduleFailed(
                            context.applicationContext,
                            expected,
                            deliveryStore,
                            cancelScheduled,
                        )
                    }
                },
                { command -> command.run() },
            )
        }
        true
    } catch (_: Exception) {
        scheduleFailed(
            context.applicationContext,
            expected,
            deliveryStore,
            cancel ?: {
                WorkManager.getInstance(context.applicationContext).cancelAllWorkByTag(TAG)
                Unit
            },
        )
        false
    }

    private fun scheduleFailed(
        context: Context,
        expected: LocalNotificationDeliveryRecord,
        deliveryStore: LocalNotificationDeliveryStore,
        cancel: () -> Unit,
    ) = synchronized(LIFECYCLE_LOCK) {
        val current = deliveryStore.load() ?: return@synchronized
        if (!sameAuthority(expected, current) || !samePlatformAuthority(context, current)) {
            return@synchronized
        }
        markRecovery(context, "workScheduleUnavailable")
        runCatching(cancel)
    }

    internal fun sameAuthority(
        expected: LocalNotificationDeliveryRecord,
        current: LocalNotificationDeliveryRecord,
    ): Boolean = expected.copy(cursor = current.cursor) == current

    private fun samePlatformAuthority(
        context: Context,
        record: LocalNotificationDeliveryRecord,
    ): Boolean {
        val platform = context.getSharedPreferences(
            LocalNotificationRenderer.PLATFORM_STORE,
            Context.MODE_PRIVATE,
        )
        return record.bindingId == platform.getString("binding_id", null) &&
            record.subscriptionId == platform.getString("subscription_id", null) &&
            record.subscriptionRevision == platform.getLong("subscription_revision", 0L)
    }

    fun scheduleCatchUp(context: Context, record: LocalNotificationDeliveryRecord, depth: Int) {
        if (depth > MAX_CATCH_UP_DEPTH) return
        try {
            val request = OneTimeWorkRequestBuilder<LocalNotificationDeliveryWorker>()
                .setConstraints(network)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
                .setInputData(workDataOf(INPUT_CATCH_UP_DEPTH to depth))
                .addTag(TAG)
                .build()
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                "$TAG-catch-up-${record.leaseId}-${record.cursor}",
                ExistingWorkPolicy.KEEP,
                request,
            )
        } catch (_: Exception) {
            // The durable periodic request remains the bounded fallback.
        }
    }

    fun stop(context: Context) {
        runCatching { WorkManager.getInstance(context.applicationContext).cancelAllWorkByTag(TAG) }
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

/** One bounded projection pull. WorkManager owns persistence, reboot, and timing. */
class LocalNotificationDeliveryWorker private constructor(
    context: Context,
    parameters: WorkerParameters,
    private val deliveryStore: LocalNotificationDeliveryStore,
    private val transport: LocalNotificationDeliveryTransport,
    private val renderer: LocalNotificationRenderer,
) : Worker(context, parameters) {
    constructor(context: Context, parameters: WorkerParameters) : this(
        context,
        parameters,
        LocalNotificationDeliveryStore(context),
        LocalNotificationDeliveryTransport(),
        LocalNotificationRenderer(context).also { it.createChannel() },
    )

    internal constructor(
        context: Context,
        parameters: WorkerParameters,
        deliveryStore: LocalNotificationDeliveryStore,
        transport: LocalNotificationDeliveryTransport,
    ) : this(
        context,
        parameters,
        deliveryStore,
        transport,
        LocalNotificationRenderer(context).also { it.createChannel() },
    )

    companion object {
        private const val MAX_TRANSIENT_RETRIES = 3
    }

    override fun doWork(): Result {
        val record = synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
            val sealed = deliveryStore.hasSealedRecord()
            val loaded = deliveryStore.load()
            if (loaded == null) {
                if (sealed) LocalNotificationDeliveryWork.markRecovery(applicationContext, "deliveryStateUnavailable")
                LocalNotificationDeliveryWork.stop(applicationContext)
                return Result.success()
            }
            if (!validRecord(loaded)) {
                retire(loaded, "deliveryUnavailable", clearCredential = true)
                return Result.success()
            }
            if (!renderer.canNotify()) {
                retire(loaded, "notificationPermissionRevoked", clearCredential = false)
                return Result.success()
            }
            loaded
        }

        return when (val pull = transport.pull(record)) {
            is DeliveryPullResult.Success -> applySuccess(record, pull)
            DeliveryPullResult.AuthorityRejected -> {
                retire(record, "deliveryAuthorityRejected", clearCredential = true)
                Result.success()
            }
            DeliveryPullResult.AuthorityChanged -> {
                retire(record, "deliveryAuthorityChanged", clearCredential = false)
                Result.success()
            }
            DeliveryPullResult.LeaseRenewalRequired -> {
                retire(record, "deliveryLeaseRenewalRequired", clearCredential = false)
                Result.success()
            }
            DeliveryPullResult.ProtocolRejected -> {
                retire(record, "deliveryProtocolRejected", clearCredential = false)
                Result.success()
            }
            DeliveryPullResult.TransientFailure ->
                if (runAttemptCount < MAX_TRANSIENT_RETRIES) Result.retry() else Result.success()
        }
    }

    private fun applySuccess(
        expected: LocalNotificationDeliveryRecord,
        pull: DeliveryPullResult.Success,
    ): Result {
        try {
            for (event in pull.events) {
                synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
                    val current = deliveryStore.load()
                    if (current == null || !sameAuthority(expected, current) || !validRecord(current)) {
                        return Result.success()
                    }
                    if (event.sequence <= current.cursor) return@synchronized
                    renderer.post(current.bindingId, current.subscriptionRevision, event)
                    deliveryStore.updateCursor(current.leaseId, current.leaseRevision, event.sequence)
                }
            }
            val current = synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
                deliveryStore.load()
                    ?.takeIf { sameAuthority(expected, it) && validRecord(it) }
                    ?.also { LocalNotificationDeliveryWork.clearRecovery(applicationContext) }
            } ?: return Result.success()
            if (pull.more) {
                val depth = inputData.getInt(LocalNotificationDeliveryWork.INPUT_CATCH_UP_DEPTH, 0)
                LocalNotificationDeliveryWork.scheduleCatchUp(applicationContext, current, depth + 1)
            }
            return Result.success()
        } catch (_: Exception) {
            val stillCurrent = synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
                deliveryStore.load()?.let { sameAuthority(expected, it) && validRecord(it) } == true
            }
            return if (stillCurrent && runAttemptCount < MAX_TRANSIENT_RETRIES) Result.retry() else Result.success()
        }
    }

    private fun retire(
        expected: LocalNotificationDeliveryRecord,
        reason: String,
        clearCredential: Boolean,
    ) {
        synchronized(LocalNotificationDeliveryWork.LIFECYCLE_LOCK) {
            val current = deliveryStore.load()
            if (current == null || !sameAuthority(expected, current)) return
            if (clearCredential) {
                if (!deliveryStore.clearIf(current.leaseId, current.leaseRevision)) return
                renderer.clearPostedNotifications()
            }
            LocalNotificationDeliveryWork.markRecovery(applicationContext, reason)
            LocalNotificationDeliveryWork.stop(applicationContext)
        }
    }

    private fun validRecord(record: LocalNotificationDeliveryRecord): Boolean {
        if (!record.active || record.expiresAt <= System.currentTimeMillis() / 1000.0) return false
        val platform = applicationContext.getSharedPreferences(
            LocalNotificationRenderer.PLATFORM_STORE,
            Context.MODE_PRIVATE,
        )
        return record.bindingId == platform.getString("binding_id", null) &&
            record.subscriptionId == platform.getString("subscription_id", null) &&
            record.subscriptionRevision == platform.getLong("subscription_revision", 0L)
    }

    private fun sameAuthority(
        expected: LocalNotificationDeliveryRecord,
        current: LocalNotificationDeliveryRecord,
    ): Boolean = LocalNotificationDeliveryWork.sameAuthority(expected, current)
}
