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
    private class Session : VncNativeInputSession {
        var closes = 0
        var lastInput: Map<String, Any>? = null
        override fun input(sequence: Long, event: Map<String, Any>): Boolean {
            lastInput = event
            return true
        }
        override fun close() { closes++ }
    }

    private inner class Backend(private val session: Session) : VncNativeBackend {
        var opens = 0
        override fun capabilities() = VncNativeCapabilities.parse(availableCapabilities())
        override fun open(
            request: VncNativeRequest,
            plan: VncNativePlan,
            secrets: VncNativeSecrets,
        ): VncNativeSession {
            opens++
            return session
        }
    }

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

    private fun availableCapabilities(clipboard: Boolean = false) = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "availability" to "available",
        "engineRevision" to "rfb-fixture-1",
        "rfbVersions" to listOf("3.8"),
        "securityTypes" to listOf("vencryptTlsVncAuth"),
        "transport" to mapOf("tls" to true, "spkiPinning" to true),
        "auth" to mapOf("password" to true),
        "framebuffer" to mapOf(
            "encodings" to listOf("tight"), "trueColor32" to true,
            "dynamicResolution" to true, "externalDisplay" to true,
            "maxWidth" to 8192, "maxHeight" to 8192, "maxDpi" to 640,
        ),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to clipboard),
    )

    private fun request(clipboard: Boolean = false) = mapOf<String, Any?>(
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
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to clipboard),
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
            "binding" to binding(), "request" to request(),
            "expectedEngineRevision" to null, "password" to password,
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
        val session = Session()
        val bridge = VncNativeBridge(
            messenger = messenger,
            adapter = VncNativeAdapter(Backend(session)),
        )
        val sink = Sink()
        bridge.onListen(null, sink)
        bridge.setResumed(true)
        bridge.onMethodCall(MethodCall("activate", binding()), Result())
        val password = "secret".encodeToByteArray()
        val opened = Result()
        bridge.onMethodCall(MethodCall("open", mapOf(
            "binding" to binding(), "request" to request(),
            "expectedEngineRevision" to "rfb-fixture-1", "password" to password,
        )), opened)
        assertNull(opened.error)
        assertTrue(password.all { it == 0.toByte() })
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
        assertEquals(1, session.closes)
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

    @Test
    fun openBindsTheExactCapabilityRevisionBeforeBackendHandoff() {
        val messenger = Messenger()
        val session = Session()
        val backend = Backend(session)
        val bridge = VncNativeBridge(
            messenger = messenger,
            adapter = VncNativeAdapter(backend),
        )
        bridge.setResumed(true)
        bridge.onMethodCall(MethodCall("activate", binding()), Result())
        val password = "secret".encodeToByteArray()
        val stale = Result()
        bridge.onMethodCall(MethodCall("open", mapOf(
            "binding" to binding(), "request" to request(),
            "expectedEngineRevision" to "rfb-fixture-0", "password" to password,
        )), stale)
        assertEquals("staleSession", stale.error)
        assertEquals(0, backend.opens)
        assertTrue(password.all { it == 0.toByte() })
        bridge.dispose()
    }

    @Test
    fun clipboardTextRequiresTheExplicitNegotiatedChannel() {
        val messenger = Messenger()
        val session = Session()
        val backend = object : VncNativeBackend {
            override fun capabilities() = VncNativeCapabilities.parse(
                availableCapabilities(clipboard = true),
            )
            override fun open(
                request: VncNativeRequest,
                plan: VncNativePlan,
                secrets: VncNativeSecrets,
            ): VncNativeSession = session
        }
        val bridge = VncNativeBridge(messenger, VncNativeAdapter(backend))
        bridge.setResumed(true)
        bridge.onMethodCall(MethodCall("activate", binding()), Result())
        bridge.onMethodCall(MethodCall("open", mapOf(
            "binding" to binding(), "request" to request(clipboard = true),
            "expectedEngineRevision" to "rfb-fixture-1",
            "password" to "secret".encodeToByteArray(),
        )), Result())
        val sent = Result()
        bridge.onMethodCall(MethodCall("input", mapOf(
            "binding" to binding(), "sequence" to 1L,
            "event" to mapOf("kind" to "clipboard", "text" to "Merhaba dünya"),
        )), sent)
        assertNull(sent.error)
        assertEquals(
            mapOf("kind" to "clipboard", "text" to "Merhaba dünya"),
            session.lastInput,
        )
        bridge.dispose()
    }
}
