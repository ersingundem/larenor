package com.ersingundem.larenor.window

import android.app.Activity
import android.app.Application
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
class WindowPolicyBridgeTest {
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            handlers[channel] = handler
        }
    }
    private class Result : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var missing = false
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { error = code }
        override fun notImplemented() { missing = true }
    }
    @Test fun actualBridgeReadsPublicStateRejectsManagementMethodsAndDetachesChannels() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val messenger = Messenger()
        val bridge = WindowPolicyBridge(activity.get(), messenger)
        try {
            val result = Result()
            bridge.onMethodCall(MethodCall("snapshot", null), result)
            val map = result.value as Map<*, *>
            assertEquals(15, map.size)
            assertEquals("adaptive", map["requestedProfile"])
            assertEquals(false, map["isResumed"])
            val invalid = Result()
            bridge.onMethodCall(MethodCall("setProfile", mapOf("profile" to "kiosk")), invalid)
            assertEquals("invalidProfile", invalid.error)
            val forbidden = Result()
            bridge.onMethodCall(MethodCall("startLockTask", null), forbidden)
            assertTrue(forbidden.missing)
            bridge.setResumed(true)
            bridge.windowChanged()
            bridge.setResumed(false)
            bridge.dispose()
            assertTrue(messenger.handlers.values.all { it == null })
            val after = Result()
            bridge.onMethodCall(MethodCall("setProfile", mapOf("profile" to "panel")), after)
            assertEquals("unavailable", after.error)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }
}
