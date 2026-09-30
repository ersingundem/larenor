package com.ersingundem.larenor.kiosk

import android.app.Activity
import android.app.Application
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class KioskPeripheralBridgeTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit
    }

    private class Result : MethodChannel.Result {
        var value: Any? = null
        var code: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { this.code = code }
        override fun notImplemented() = Unit
    }

    @Test fun capabilitiesAreBoundedReviewOnlyPlatformFacts() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val bridge = KioskPeripheralBridge(activity.get(), Messenger())
        try {
            val result = Result()
            bridge.onMethodCall(MethodCall("capabilities", null), result)
            assertNull(result.code)
            val raw = result.value as Map<*, *>
            assertEquals(1, raw["schemaVersion"])
            assertEquals(false, raw["gmsAvailable"])
            val inventory = raw["inventory"] as Map<*, *>
            assertEquals(1, inventory["schemaVersion"])
            assertTrue((inventory["inventoryRevision"] as Int) > 0)
            val providers = inventory["providers"] as List<*>
            assertEquals(6, providers.size)
            assertEquals(
                PeripheralKind.entries.map { it.name }.toSet(),
                providers.map { (it as Map<*, *>)["kind"] }.toSet(),
            )
            providers.forEach {
                val provider = it as Map<*, *>
                assertEquals(false, provider["enabledByUser"])
                assertEquals(false, provider["requiresGms"])
                assertTrue(provider["permission"] in setOf("notRequired", "granted", "unknown"))
                assertFalse(provider.containsKey("execute"))
                assertFalse(provider.containsKey("javascript"))
            }
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test fun explicitRetirementIsIdempotentAndRejectsArguments() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val bridge = KioskPeripheralBridge(activity.get(), Messenger())
        try {
            val first = Result()
            bridge.onMethodCall(MethodCall("retire", null), first)
            assertNull(first.code)
            assertNull(first.value)
            val second = Result()
            bridge.onMethodCall(MethodCall("retire", null), second)
            assertNull(second.code)
            val invalid = Result()
            bridge.onMethodCall(MethodCall("retire", emptyMap<String, Any>()), invalid)
            assertEquals("invalid", invalid.code)
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }
}
