package com.ersingundem.larenor.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Marks recovery only; boot never starts network work or a foreground service. */
class LocalNotificationBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        context.getSharedPreferences("larenor_local_notification_platform_v1", Context.MODE_PRIVATE)
            .edit().putBoolean("recovery_required", true).apply()
    }
}
