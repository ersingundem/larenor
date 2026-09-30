package com.ersingundem.larenor.game

import android.app.Activity
import android.app.Application
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.function.Consumer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class GameStreamNativeBridgeTest {
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            handlers[channel] = handler
        }
    }

    private class Reply : MethodChannel.Result {
        var completions = 0
        var value: Any? = null
        var code: String? = null
        var message: String? = null
        override fun success(result: Any?) { completions++; value = result }
        override fun error(code: String, message: String?, details: Any?) {
            completions++; this.code = code; this.message = message
        }
        override fun notImplemented() { completions++ }
    }

    private class Host : GameStreamEmbeddedHost {
        val calls = mutableListOf<String>()
        val resumes = mutableListOf<Boolean>()
        val focus = mutableListOf<Boolean>()
        var closed = 0
        var success: Consumer<Any?>? = null
        var error: Consumer<String>? = null
        override fun handle(method: String, arguments: Any?, success: Consumer<Any?>, error: Consumer<String>): Boolean {
            calls += method; this.success = success; this.error = error
            return true
        }
        override fun setResumed(value: Boolean) { resumes += value }
        override fun setWindowFocused(value: Boolean) { focus += value }
        override fun dispose() { closed++ }
    }

    @Test fun packagedHostOwnsOneChannelAndCompletesExactlyOnce() {
        val messenger = Messenger()
        val host = Host()
        val bridge = GameStreamNativeBridge(messenger, embeddedHost = host)
        bridge.setResumed(true)
        val reply = Reply()
        bridge.onMethodCall(MethodCall("beginPairingV2", mapOf("schemaVersion" to 2)), reply)
        assertEquals(listOf("beginPairingV2"), host.calls)
        host.success!!.accept(mapOf("requestId" to "owned-request"))
        host.error!!.accept("provider_unavailable")
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, reply.completions)
        assertNull(reply.code)
        assertEquals(setOf(GameStreamNativeBridge.CHANNEL), messenger.handlers.keys)
        bridge.dispose()
        assertNull(messenger.handlers[GameStreamNativeBridge.CHANNEL])
        assertEquals(1, host.closed)
    }

    @Test fun backgroundCannotStartNewPairingAndLifecycleReachesExactHost() {
        val host = Host()
        val bridge = GameStreamNativeBridge(Messenger(), embeddedHost = host)
        bridge.setResumed(true)
        bridge.setWindowFocused(false)
        val refused = Reply()
        bridge.onMethodCall(MethodCall("beginPairingV2", null), refused)
        assertEquals("foreground_required", refused.code)
        assertEquals(emptyList<String>(), host.calls)
        // Native owns the exact lease check for a terminating stream; no new transfer is granted.
        bridge.onMethodCall(MethodCall("reconcileV2", null), Reply())
        assertEquals(listOf("reconcileV2"), host.calls)
        bridge.setResumed(false)
        assertEquals(listOf(true, false), host.resumes)
        assertEquals(listOf(false), host.focus)
        bridge.dispose()
    }

    @Test fun disposedBridgeRejectsLatePrivateResultAndRedactsUnexpectedError() {
        val host = Host()
        val bridge = GameStreamNativeBridge(Messenger(), embeddedHost = host)
        bridge.setResumed(true)
        val reply = Reply()
        bridge.onMethodCall(MethodCall("pairHostV2", null), reply)
        bridge.dispose()
        host.success!!.accept(mapOf("private" to "must-not-be-published"))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("authority_changed", reply.code)
        assertNull(reply.value)
        assertEquals(1, reply.completions)
        val unexpectedHost = Host()
        val third = GameStreamNativeBridge(Messenger(), embeddedHost = unexpectedHost)
        third.setResumed(true)
        val redacted = Reply()
        third.onMethodCall(MethodCall("pairHostV2", null), redacted)
        unexpectedHost.error!!.accept("raw-secret-path")
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("unknown_effect", redacted.code)
        assertNull(redacted.message)
        third.dispose()
    }

    @Test fun productionModeWithoutPackagedHostCannotFallBackToHandoff() {
        val activity = Robolectric.buildActivity(Activity::class.java).get()
        val bridge = GameStreamNativeBridge(Messenger(), activity = activity, embeddedHost = null)
        bridge.setResumed(true)
        for (method in listOf("beginPairingV2", "executeV2", "openProvider")) {
            val reply = Reply()
            bridge.onMethodCall(MethodCall(method, null), reply)
            assertEquals("engine_unavailable", reply.code)
        }
        bridge.dispose()
    }
}
