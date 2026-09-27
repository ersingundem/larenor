package com.ersingundem.larenor.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restores an explicitly provisioned delivery lease after reboot or app update. */
class LocalNotificationBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        val deliveryStore = LocalNotificationDeliveryStore(context)
        val hadSealedRecord = deliveryStore.hasSealedRecord()
        val record = deliveryStore.load()
        val platform = context.getSharedPreferences(LocalNotificationRenderer.PLATFORM_STORE, Context.MODE_PRIVATE)
        val valid = record?.active == true && record.expiresAt > System.currentTimeMillis() / 1000.0 &&
            record.bindingId == platform.getString("binding_id", null) &&
            record.subscriptionId == platform.getString("subscription_id", null) &&
            record.subscriptionRevision == platform.getLong("subscription_revision", 0L) &&
            LocalNotificationRenderer(context).apply { createChannel() }.canNotify()
        if (valid) {
            LocalNotificationDeliveryRuntime.clearRecovery(context)
            if (!LocalNotificationDeliveryRuntime.start(context)) {
                LocalNotificationDeliveryRuntime.markRecovery(context, "bootStartDenied")
            }
        } else if (hadSealedRecord) {
            LocalNotificationDeliveryRuntime.markRecovery(context, "bootRecoveryRequired")
        }
    }
}
