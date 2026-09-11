package com.ersingundem.larenor.vnc

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VncNativeBridgeTest {
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
        var error: String? = null
        var message: String? = null
        var details: Any? = "unset"
        var missing = false
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) {
            error = code
            this.message = message
            this.details = details
        }
        override fun notImplemented() { missing = true }
    }

    private class Sink : EventChannel.EventSink {
        val values = mutableListOf<Any?>()
        var errors = 0
        var ended = false
        override fun success(event: Any?) { values += event }
        override fun error(code: String, message: String?, details: Any?) { errors++ }
        override fun endOfStream() { ended = true }
    }

    private fun binding(owner: String = "22222222-2222-4222-8222-222222222222") = mapOf(
        "ownerId" to owner,
        "accountRevision" to 7,
        "routeRevision" to 11,
    )

    private fun request() = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to "11111111-1111-4111-8111-111111111111",
        "targetHost" to "desktop.home.arpa",
        "targetPort" to 5900,
        "security" to mapOf(
            "type" to "vencryptTlsVncAuth",
            "spkiFingerprint" to "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "requiresPassword" to true,
        ),
        "display" to mapOf(
            "width" to 1280,
            "height" to 800,
            "dpi" to 180,
            "externalDisplay" to false,
            "dynamicResolution" to true,
        ),
        "framebuffer" to mapOf("encoding" to "tight", "pixelFormat" to "trueColor32"),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    )

    @Test
    fun actualMethodChannelDefaultsUnavailableAndDetachesWithoutNetwork() {
        val messenger = Messenger()
        val bridge = VncNativeBridge(messenger = messenger)
        assertEquals(setOf(VncNativeBridge.METHODS, VncNativeBridge.EVENTS), messenger.handlers.keys)
        val capabilities = Result()
        bridge.onMethodCall(MethodCall("capabilities", null), capabilities)
        assertEquals("unavailable", (capabilities.value as Map<*, *>)["availability"])
        bridge.setResumed(true)
        val active = Result()
        bridge.onMethodCall(MethodCall("activate", binding()), active)
        assertNull(active.error)
        val password = "secret".encodeToByteArray()
        val open = Result()
        bridge.onMethodCall(MethodCall("open", mapOf(
            "binding" to binding(), "request" to request(), "password" to password,
        )), open)
        assertEquals("engineUnavailable", open.error)
        assertEquals("Native VNC unavailable", open.message)
        assertNull(open.details)
        assertTrue(password.all { it == 0.toByte() })
        bridge.dispose()
        assertTrue(messenger.handlers.values.all { it == null })
    }

    @Test
    fun lifecycleBindingAndFrameWindowFailClosedWithOneOutstandingFrame() {
        val messenger = Messenger()
        val bridge = VncNativeBridge(messenger = messenger)
        val sink = Sink()
        bridge.onListen(null, sink)
        bridge.setResumed(true)
        bridge.onMethodCall(MethodCall("activate", binding()), Result())
        assertTrue(bridge.publishFrame(binding(), 1, 1280, 800, 4_096_000))
        assertFalse(bridge.publishFrame(binding(), 2, 1280, 800, 4_096_000))
        assertEquals(1, sink.values.size)
        val frame = sink.values.single() as Map<*, *>
        assertEquals(1L, frame["sequence"])
        assertFalse(frame.keys.any { it in setOf("pixels", "targetHost", "password") })
        val ack = Result()
        bridge.onMethodCall(MethodCall("ackFrame", mapOf(
            "binding" to binding(), "sequence" to 1L,
        )), ack)
        assertNull(ack.error)
        assertFalse(bridge.publishFrame(binding(), 3, 1280, 800, 4_096_000))
        val afterGap = Result()
        bridge.onMethodCall(MethodCall("input", mapOf(
            "binding" to binding(), "sequence" to 1L,
            "event" to mapOf("kind" to "key", "code" to 40, "down" to true),
        )), afterGap)
        assertEquals("staleSession", afterGap.error)
        bridge.setResumed(false)
        bridge.onCancel(null)
        bridge.dispose()
    }

    @Test
    fun invalidOwnerAndNativeDiagnosticsExposeOnlyClosedErrors() {
        val messenger = Messenger()
        val bridge = VncNativeBridge(messenger = messenger)
        bridge.setResumed(true)
        bridge.onMethodCall(MethodCall("activate", binding()), Result())
        val stale = Result()
        bridge.onMethodCall(MethodCall("cancel", binding("33333333-3333-4333-8333-333333333333")), stale)
        assertEquals("staleSession", stale.error)
        assertNull(stale.details)
        assertFalse(stale.message.orEmpty().contains("33333333"))
        val invalid = Result()
        bridge.onMethodCall(MethodCall("open", mapOf("password" to "plaintext")), invalid)
        assertEquals("invalidRequest", invalid.error)
        assertNull(invalid.details)
        bridge.dispose()
    }
}
