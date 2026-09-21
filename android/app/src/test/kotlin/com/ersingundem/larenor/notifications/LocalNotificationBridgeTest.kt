package com.ersingundem.larenor.notifications

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.app.NotificationChannel
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalNotificationBridgeTest {
    private class Reply { var value: Any? = null; var error: String? = null; var replies = 0 }
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) { handlers[channel] = handler }
        fun call(method: String, arguments: Any? = null): Reply {
            val reply = Reply(); val codec = StandardMethodCodec.INSTANCE
            val buffer = codec.encodeMethodCall(MethodCall(method, arguments)); buffer.flip()
            handlers[LocalNotificationBridge.METHODS]!!.onMessage(buffer) { raw ->
                reply.replies++; raw!!.flip()
                try { reply.value = codec.decodeEnvelope(raw) }
                catch (error: FlutterException) {
                    reply.error = error.code
                    assertNull(error.details)
                    assertFalse(error.message.orEmpty().contains("Secret"))
                }
            }
            return reply
        }
    }
    private class Sink : EventChannel.EventSink {
        val values = mutableListOf<Any?>(); var error: String? = null
        override fun success(event: Any?) { values.add(event) }
        override fun error(code: String, message: String?, details: Any?) { error = code; assertNull(details) }
        override fun endOfStream() {}
    }
    private fun activity() = Robolectric.buildActivity(Activity::class.java).setup().visible().windowFocusChanged(true)
    private fun bind(binding: String = "a".repeat(64), revision: Long = 3) = mapOf(
        "schemaVersion" to 1, "bindingId" to binding,
        "subscriptionId" to "b".repeat(32), "subscriptionRevision" to revision)
    private fun event(sequence: Long, private: Boolean = false) = mapOf(
        "schemaVersion" to 1, "id" to (if (sequence == 1L) "c" else "d").repeat(32),
        "sequence" to sequence, "sensitivity" to if (private) "private" else "public",
        "title" to if (private) "Larenor" else "Door",
        "body" to if (private) "" else "Opened", "redacted" to private)
    private fun event(id: String, sequence: Long) = mapOf(
        "schemaVersion" to 1, "id" to id, "sequence" to sequence,
        "sensitivity" to "public", "title" to "Workshop", "body" to "Ready",
        "redacted" to false)
    private fun reconcile(events: List<Map<String, Any>>, revision: Long = 3) = bind(revision = revision) + mapOf("events" to events)
    private fun pump() = Shadows.shadowOf(Looper.getMainLooper()).idle()

    @Test fun android13PermissionIsExplicitAndDenialNeverRePrompts() {
        val activity = activity(); val messenger = Messenger()
        val bridge = LocalNotificationBridge(activity.get(), messenger)
        try {
            bridge.setResumed(true)
            assertEquals("notRequested", (messenger.call("probe").value as Map<*, *>)["permission"])
            val request = messenger.call("requestPermission")
            assertEquals(0, request.replies)
            // The Android permission dialog owns focus while it is visible.
            activity.windowFocusChanged(false); bridge.windowChanged()
            assertEquals(0, request.replies)
            assertTrue(bridge.onRequestPermissionsResult(LocalNotificationBridge.REQUEST_NOTIFICATIONS,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS), intArrayOf(PackageManager.PERMISSION_DENIED)))
            assertEquals("denied", (request.value as Map<*, *>)["permission"])
            activity.windowFocusChanged(true); bridge.windowChanged()
            val again = messenger.call("requestPermission")
            assertEquals(1, again.replies)
            assertEquals("denied", (again.value as Map<*, *>)["permission"])
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun privateNotificationIsRedactedAndTapIsOneShotScoped() {
        val activity = activity(); val messenger = Messenger()
        Shadows.shadowOf(activity.get().application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val bridge = LocalNotificationBridge(activity.get(), messenger)
        val sink = Sink()
        try {
            bridge.setResumed(true); bridge.onListen(null, sink)
            assertNull(messenger.call("bind", bind()).error)
            assertNull(messenger.call("reconcile", reconcile(listOf(event(1, private = true)))).error)
            val manager = activity.get().getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val notification = manager.activeNotifications.single().notification
            assertEquals("Larenor", notification.extras.getString("android.title"))
            assertFalse(notification.extras.toString().contains("Secret"))
            assertEquals(android.app.Notification.VISIBILITY_PRIVATE, notification.visibility)
            val tap = Shadows.shadowOf(notification.contentIntent).savedIntent
            assertTrue(bridge.handleIntent(Intent(tap)))
            assertEquals(1, sink.values.size)
            val value = sink.values.single() as Map<*, *>
            assertEquals("a".repeat(64), value["bindingId"])
            assertEquals(1L, value["sequence"])
            assertFalse(bridge.handleIntent(Intent(tap)))
            assertEquals(1, sink.values.size)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun duplicateOutOfOrderAndStaleRevisionFailClosed() {
        val activity = activity(); val messenger = Messenger()
        Shadows.shadowOf(activity.get().application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val bridge = LocalNotificationBridge(activity.get(), messenger)
        try {
            bridge.setResumed(true)
            assertNull(messenger.call("bind", bind()).error)
            assertEquals("outOfOrder", messenger.call("reconcile", reconcile(listOf(event(2), event(1)))).error)
            assertNull(messenger.call("reconcile", reconcile(listOf(event(1), event(2)))).error)
            val manager = activity.get().getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            assertEquals(2, manager.activeNotifications.size)
            assertNull(messenger.call("reconcile", reconcile(listOf(event(1), event(2)))).error)
            assertEquals(2, manager.activeNotifications.size)
            assertNull(messenger.call("reconcile", reconcile(listOf(event(2)))).error)
            assertEquals(1, manager.activeNotifications.size)
            assertNull(messenger.call("reconcile", reconcile(emptyList())).error)
            assertEquals(0, manager.activeNotifications.size)
            assertEquals("stale", messenger.call("reconcile", reconcile(listOf(event(2)), revision = 2)).error)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun distinctEventIdsWithTheSameJavaHashKeepIndependentNotificationsAndTaps() {
        val firstId = "0bdd2de831d8ea06add2fdb3b7860188"
        val secondId = "501c0fb5a15f0056584727a18806728c"
        assertNotEquals(firstId, secondId)
        assertEquals(firstId.hashCode(), secondId.hashCode())
        val activity = activity(); val messenger = Messenger()
        Shadows.shadowOf(activity.get().application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val bridge = LocalNotificationBridge(activity.get(), messenger)
        val sink = Sink()
        try {
            bridge.setResumed(true); bridge.onListen(null, sink)
            assertNull(messenger.call("bind", bind()).error)
            assertNull(messenger.call("reconcile", reconcile(listOf(
                event(firstId, 1), event(secondId, 2),
            ))).error)
            val manager = activity.get().getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            assertEquals(2, manager.activeNotifications.size)
            val taps = manager.activeNotifications.map { Shadows.shadowOf(it.notification.contentIntent).savedIntent }
            assertTrue(taps.all { bridge.handleIntent(Intent(it)) })
            assertEquals(setOf(firstId, secondId), sink.values.map { (it as Map<*, *>)["eventId"] }.toSet())
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun bootOnlyMarksBoundedRecoveryAndPowerActionNeverRequestsExemption() {
        val activity = activity(); val messenger = Messenger()
        val manager = activity.get().getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            "larenor_local_notifications_v0", "Old", NotificationManager.IMPORTANCE_LOW))
        val bridge = LocalNotificationBridge(activity.get(), messenger)
        try {
            assertNotNull(manager.getNotificationChannel(LocalNotificationBridge.CHANNEL_ID))
            assertNull(manager.getNotificationChannel("larenor_local_notifications_v0"))
            LocalNotificationBootReceiver().onReceive(activity.get(), Intent(Intent.ACTION_BOOT_COMPLETED))
            assertEquals(true, (messenger.call("probe").value as Map<*, *>)["recoveryRequired"])
            bridge.setResumed(true)
            assertEquals(false, (messenger.call("bind", bind()).value as Map<*, *>)["recoveryRequired"])
            assertNull(messenger.call("openPowerSettings").error)
            val launched = Shadows.shadowOf(activity.get()).nextStartedActivity
            assertNotEquals(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, launched.action)
            assertNull(Shadows.shadowOf(activity.get()).nextStartedService)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun processRestartKeepsHighWaterAndDoesNotDuplicateDeliveredEvent() {
        val activity = activity()
        Shadows.shadowOf(activity.get().application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val firstMessenger = Messenger()
        val first = LocalNotificationBridge(activity.get(), firstMessenger)
        first.setResumed(true)
        assertNull(firstMessenger.call("bind", bind()).error)
        assertNull(firstMessenger.call("reconcile", reconcile(listOf(event(1)))).error)
        first.dispose()

        val secondMessenger = Messenger()
        val second = LocalNotificationBridge(activity.get(), secondMessenger)
        try {
            second.setResumed(true)
            assertNull(secondMessenger.call("bind", bind()).error)
            assertNull(secondMessenger.call("reconcile", reconcile(listOf(event(1), event(2)))).error)
            val manager = activity.get().getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            assertEquals(2, manager.activeNotifications.size)
            assertEquals(2L, (secondMessenger.call("probe").value as Map<*, *>)["lastSequence"])
        } finally { second.dispose(); activity.pause().stop().destroy() }
    }
}
