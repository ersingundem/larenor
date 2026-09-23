package com.ersingundem.larenor.kioskremote

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.BatteryManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ManagedTabletSourceBridgeTest {
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            handlers[channel] = handler
        }
    }

    private class Result : MethodChannel.Result {
        var value: Any? = null
        var code: String? = null
        var missing = false
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) {
            this.code = code
            assertNull(details)
        }
        override fun notImplemented() { missing = true }
    }

    private class Host : ManagedTabletSnapshotHost {
        var reads = 0
        override fun read(appForeground: Boolean): ManagedTabletNativeSnapshot {
            reads += 1
            return ManagedTabletNativeSnapshot(73, "wifi", "1.2.3+45", appForeground, "locked")
        }
    }

    @Test fun defaultDisabledAndPauseRetireTheNativeSession() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val host = Host()
        val bridge = ManagedTabletSourceBridge(activity.get(), Messenger(), host)
        try {
            bridge.setResumed(true)
            val before = Result()
            bridge.onMethodCall(MethodCall("snapshot", mapOf("sessionId" to "a".repeat(32))), before)
            assertEquals("denied", before.code)
            assertEquals(0, host.reads)

            val disabled = Result()
            bridge.onMethodCall(MethodCall("start", mapOf(
                "schemaVersion" to 1, "enabled" to false,
                "sessionId" to "a".repeat(32), "scope" to "scope-one",
            )), disabled)
            assertEquals(mapOf("status" to "disabled"), disabled.value)
            assertEquals(0, host.reads)

            val active = Result()
            bridge.onMethodCall(MethodCall("start", mapOf(
                "schemaVersion" to 1, "enabled" to true,
                "sessionId" to "a".repeat(32), "scope" to "scope-one",
            )), active)
            assertEquals(mapOf("status" to "active"), active.value)
            val snapshot = Result()
            bridge.onMethodCall(MethodCall("snapshot", mapOf("sessionId" to "a".repeat(32))), snapshot)
            val map = snapshot.value as Map<*, *>
            assertEquals(setOf("schemaVersion", "batteryPercent", "network", "appVersion", "appForeground", "kioskState"), map.keys)
            assertEquals(true, map["appForeground"])
            assertFalse(map.toString().contains("token", ignoreCase = true))
            assertFalse(map.toString().contains("://"))

            bridge.setResumed(false)
            val stale = Result()
            bridge.onMethodCall(MethodCall("snapshot", mapOf("sessionId" to "a".repeat(32))), stale)
            assertEquals("denied", stale.code)
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test fun scopeReplacementAndStaleStopCannotControlTheNewSession() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val bridge = ManagedTabletSourceBridge(activity.get(), Messenger(), Host())
        try {
            bridge.setResumed(true)
            fun start(id: String, scope: String) = Result().also {
                bridge.onMethodCall(MethodCall("start", mapOf(
                    "schemaVersion" to 1, "enabled" to true, "sessionId" to id, "scope" to scope,
                )), it)
            }
            val old = "a".repeat(32)
            val current = "b".repeat(32)
            assertNull(start(old, "scope-one").code)
            assertNull(start(current, "scope-two").code)

            val staleRead = Result()
            bridge.onMethodCall(MethodCall("snapshot", mapOf("sessionId" to old)), staleRead)
            assertEquals("denied", staleRead.code)
            val staleStop = Result()
            bridge.onMethodCall(MethodCall("stop", mapOf("sessionId" to old)), staleStop)
            assertNull(staleStop.code)
            val liveRead = Result()
            bridge.onMethodCall(MethodCall("snapshot", mapOf("sessionId" to current)), liveRead)
            assertNotNull(liveRead.value)
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test fun invalidOrSecretBearingArgumentsFailClosed() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val bridge = ManagedTabletSourceBridge(activity.get(), Messenger(), Host())
        try {
            bridge.setResumed(true)
            for (arguments in listOf(
                mapOf("schemaVersion" to 1, "enabled" to true, "sessionId" to "short", "scope" to "scope"),
                mapOf("schemaVersion" to 1, "enabled" to true, "sessionId" to "a".repeat(32), "scope" to "https://host/token"),
                mapOf("schemaVersion" to 1, "enabled" to true, "sessionId" to "a".repeat(32), "scope" to "scope", "token" to "secret"),
            )) {
                val result = Result()
                bridge.onMethodCall(MethodCall("start", arguments), result)
                assertEquals("invalid", result.code)
            }
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Suppress("DEPRECATION")
    @Test fun productionHostReadsOnlyBoundedPlatformState() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            activity.get().sendStickyBroadcast(Intent(Intent.ACTION_BATTERY_CHANGED).apply {
                putExtra(BatteryManager.EXTRA_LEVEL, 37)
                putExtra(BatteryManager.EXTRA_SCALE, 50)
            })

            val snapshot = AndroidManagedTabletSnapshotHost(activity.get()).read(appForeground = true)

            assertEquals(74, snapshot.batteryPercent)
            assertTrue(snapshot.network in setOf("offline", "wifi", "ethernet", "cellular", "other"))
            assertTrue(snapshot.appVersion.length in 1..64)
            assertTrue(snapshot.appForeground)
            assertEquals("none", snapshot.kioskState)
            assertEquals(
                setOf("schemaVersion", "batteryPercent", "network", "appVersion", "appForeground", "kioskState"),
                snapshot.toWire().keys,
            )
        } finally {
            activity.pause().stop().destroy()
        }
    }
}
