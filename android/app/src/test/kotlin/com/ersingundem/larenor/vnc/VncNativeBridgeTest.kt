package com.ersingundem.larenor.vnc

import android.app.Application
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class VncNativeBridgeTest {
    private class Session : VncNativeInputSession, VncNativeFrameSession {
        var closes = 0
        var lastInput: Map<String, Any>? = null
        override fun input(sequence: Long, event: Map<String, Any>): Boolean {
            lastInput = event
            return true
        }
        override fun acknowledgeFrame(sequence: Long) = sequence > 0
        override fun resize(width: Int, height: Int) = width > 0 && height > 0
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
    fun actualMethodChannelAdvertisesPackagedBackendAndDetachesWithoutNetwork() {
        val messenger = Messenger()
        val bridge = VncNativeBridge(messenger = messenger)
        assertEquals(setOf(VncNativeBridge.METHODS, VncNativeBridge.EVENTS), messenger.handlers.keys)
        val capabilities = Result()
        bridge.onMethodCall(MethodCall("capabilities", null), capabilities)
        val raw = capabilities.value as Map<*, *>
        assertEquals("available", raw["availability"])
        assertEquals("android-rfb-vencrypt-1", raw["engineRevision"])
        bridge.dispose()
        assertTrue(messenger.handlers.values.all { it == null })
    }

    @Test
    fun productionOpenAllowsOnlyOneNetworkJobAndZeroizesCallerPassword() {
        val address = NetworkInterface.getNetworkInterfaces().toList()
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .first { !it.isAnyLocalAddress && !it.isLoopbackAddress && !it.isLinkLocalAddress && !it.isMulticastAddress }
        val server = ServerSocket(0, 1, address)
        val accepted = CountDownLatch(1)
        val release = CountDownLatch(1)
        val accepts = AtomicInteger()
        val serverWorker = Executors.newSingleThreadExecutor()
        serverWorker.execute {
            server.accept().use {
                accepts.incrementAndGet()
                accepted.countDown()
                release.await(2, TimeUnit.SECONDS)
            }
        }
        val bridge = VncNativeBridge(Messenger())
        try {
            bridge.setResumed(true)
            bridge.onMethodCall(MethodCall("activate", binding()), Result())
            val localRequest = request().toMutableMap().apply {
                this["targetHost"] = address.hostAddress
                this["targetPort"] = server.localPort
                this["framebuffer"] = mapOf("encoding" to "raw", "pixelFormat" to "trueColor32")
            }
            val password = "secret".encodeToByteArray()
            val opening = Result()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "binding" to binding(), "request" to localRequest,
                "expectedEngineRevision" to "android-rfb-vencrypt-1", "password" to password,
            )), opening)
            assertTrue(accepted.await(1, TimeUnit.SECONDS))
            assertTrue(password.all { it == 0.toByte() })

            val competing = Result()
            bridge.onMethodCall(MethodCall("inspect", mapOf(
                "targetHost" to address.hostAddress, "targetPort" to server.localPort,
            )), competing)
            assertEquals("busy", competing.error)
            assertEquals(1, accepts.get())
            assertNull(opening.value)
        } finally {
            release.countDown()
            server.close()
            serverWorker.shutdownNow()
            bridge.dispose()
        }
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
        assertTrue(bridge.publishFrame(binding(), 1, 1280, 800, ByteArray(4_096_000)))
        assertFalse(bridge.publishFrame(binding(), 2, 1280, 800, ByteArray(4_096_000)))
        assertEquals(1, sink.values.size)
        val frame = sink.values.single() as Map<*, *>
        assertEquals(1L, frame["sequence"])
        assertEquals(4_096_000, (frame["pixels"] as ByteArray).size)
        assertFalse(frame.keys.any { it in setOf("targetHost", "password") })
        val ack = Result()
        bridge.onMethodCall(MethodCall("ackFrame", mapOf(
            "binding" to binding(), "sequence" to 1L,
        )), ack)
        assertNull(ack.error)
        assertFalse(bridge.publishFrame(binding(), 3, 1280, 800, ByteArray(4_096_000)))
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

    @Test
    fun clipboardCannotEscalatePastTheExplicitSessionRequest() {
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
            "binding" to binding(), "request" to request(clipboard = false),
            "expectedEngineRevision" to "rfb-fixture-1",
            "password" to "secret".encodeToByteArray(),
        )), Result())
        val denied = Result()
        bridge.onMethodCall(MethodCall("input", mapOf(
            "binding" to binding(), "sequence" to 1L,
            "event" to mapOf("kind" to "clipboard", "text" to "private"),
        )), denied)
        assertEquals("inputUnavailable", denied.error)
        assertNull(session.lastInput)
        assertEquals(1, session.closes)
        bridge.dispose()
    }
}
