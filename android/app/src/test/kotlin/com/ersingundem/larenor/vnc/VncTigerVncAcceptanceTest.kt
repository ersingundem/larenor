package com.ersingundem.larenor.vnc

import android.app.Application
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.Collections
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Opt-in interoperability acceptance against an externally owned TigerVNC Xvnc process.
 *
 * The normal unit suite skips this class. tool/f61_tigervnc_acceptance.py owns the isolated
 * server, supplies only its numeric fixture address and synthetic password, and removes it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class VncTigerVncAcceptanceTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) = Unit
        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) = Unit
    }

    private class Result : MethodChannel.Result {
        @Volatile var value: Any? = null
        @Volatile var error: String? = null
        @Volatile var completed = false

        override fun success(result: Any?) {
            value = result
            completed = true
        }

        override fun error(code: String, message: String?, details: Any?) {
            error = code
            completed = true
        }

        override fun notImplemented() {
            error = "notImplemented"
            completed = true
        }
    }

    private class Sink : EventChannel.EventSink {
        val values: MutableList<Map<*, *>> = Collections.synchronizedList(mutableListOf())
        @Volatile var error: String? = null

        override fun success(event: Any?) {
            @Suppress("UNCHECKED_CAST")
            values += event as Map<*, *>
        }

        override fun error(code: String, message: String?, details: Any?) {
            error = code
        }

        override fun endOfStream() = Unit
    }

    @Test
    fun normalBridgeInteroperatesWithOwnedTigerVncAndRetiresWithoutReplay() {
        assumeTrue(System.getenv(ENABLED) == "1")
        val host = requireEnvironment(HOST)
        val port = requireEnvironment(PORT).toInt().also { require(it in 1..65535) }
        val password = requireEnvironment(PASSWORD)
        val bridge = VncNativeBridge(Messenger())
        val sink = Sink()
        try {
            bridge.onListen(null, sink)
            bridge.setResumed(true)

            val capabilities = invoke(bridge, "capabilities", null)
            assertNull(capabilities.error)
            @Suppress("UNCHECKED_CAST")
            val capabilityMap = capabilities.value as Map<String, Any?>
            @Suppress("UNCHECKED_CAST")
            val inputCapabilities = capabilityMap["input"] as Map<String, Any>
            assertEquals(true, inputCapabilities["pointer"])
            assertEquals(true, inputCapabilities["keyboard"])
            assertEquals(false, inputCapabilities["clipboard"])

            val inspection = invoke(
                bridge,
                "inspect",
                mapOf("targetHost" to host, "targetPort" to port),
                asynchronous = true,
            )
            assertNull(inspection.error)
            @Suppress("UNCHECKED_CAST")
            val pin = (inspection.value as Map<String, Any>)["spkiFingerprint"] as String
            assertTrue(pin.startsWith("SHA256:"))

            val firstBinding = binding(routeRevision = 11)
            assertNull(invoke(bridge, "activate", firstBinding).error)
            val firstRequest = request(
                host = host,
                port = port,
                pin = pin,
                requestId = "11111111-1111-4111-8111-111111111111",
                width = 800,
                height = 600,
            )
            val firstOpen = open(bridge, firstBinding, firstRequest, password)
            assertNull(firstOpen.error)

            val firstFrame = awaitFrame(sink, firstRequest["requestId"] as String, minimumCount = 1)
            assertEquals(800, firstFrame["width"])
            assertEquals(600, firstFrame["height"])
            val firstPixels = (firstFrame["pixels"] as ByteArray).copyOf()
            assertTrue(firstPixels.toSet().size > 4)
            acknowledge(bridge, firstBinding, firstFrame)

            assertNull(input(bridge, firstBinding, 1, pointer(0.10, 0.10, 1)).error)
            assertNull(input(bridge, firstBinding, 2, pointer(0.10, 0.10, 0)).error)
            assertNull(input(bridge, firstBinding, 3, mapOf("kind" to "text", "text" to "Larenor61")).error)
            val inputFrame = awaitFrame(sink, firstRequest["requestId"] as String, minimumCount = 2)
            val inputPixels = inputFrame["pixels"] as ByteArray
            assertFalse(firstPixels.contentEquals(inputPixels))
            firstPixels.fill(0)
            acknowledge(bridge, firstBinding, inputFrame)

            val resized = invoke(bridge, "resize", mapOf(
                "binding" to firstBinding,
                "width" to 960,
                "height" to 720,
            ))
            assertNull(resized.error)
            val resizedFrame = awaitFrame(
                sink,
                firstRequest["requestId"] as String,
                minimumCount = 3,
                condition = { it["width"] == 960 && it["height"] == 720 },
            )
            assertEquals(960, resizedFrame["width"])
            assertEquals(720, resizedFrame["height"])
            acknowledge(bridge, firstBinding, resizedFrame)

            // Clipboard is deliberately unsupported by the production capability. Prove that a
            // real Xvnc session cannot turn the dormant parser shape into an outbound message.
            val clipboard = input(
                bridge,
                firstBinding,
                4,
                mapOf("kind" to "clipboard", "text" to "must-not-leave-client"),
            )
            assertEquals("inputUnavailable", clipboard.error)
            val staleAfterClipboard = input(
                bridge,
                firstBinding,
                4,
                mapOf("kind" to "text", "text" to "must-not-replay"),
            )
            assertEquals("staleSession", staleAfterClipboard.error)

            val secondBinding = binding(routeRevision = 12)
            assertNull(invoke(bridge, "activate", secondBinding).error)
            val secondRequest = request(
                host = host,
                port = port,
                pin = pin,
                requestId = "33333333-3333-4333-8333-333333333333",
                width = 960,
                height = 720,
            )
            assertNull(open(bridge, secondBinding, secondRequest, password).error)
            awaitFrame(sink, secondRequest["requestId"] as String, minimumCount = 1)
            val frameCountBeforeRetirement = sink.values.size

            bridge.setResumed(false)
            bridge.setResumed(true)
            val staleAfterAuthorityLoss = input(
                bridge,
                secondBinding,
                1,
                mapOf("kind" to "text", "text" to "must-not-replay"),
            )
            assertEquals("staleSession", staleAfterAuthorityLoss.error)
            Thread.sleep(300)
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(frameCountBeforeRetirement, sink.values.size)
        } finally {
            bridge.dispose()
        }
    }

    private fun open(
        bridge: VncNativeBridge,
        binding: Map<String, Any>,
        request: Map<String, Any?>,
        password: String,
    ): Result {
        val bytes = password.encodeToByteArray()
        val result = invoke(bridge, "open", mapOf(
            "binding" to binding,
            "request" to request,
            "expectedEngineRevision" to "android-rfb-vencrypt-1",
            "password" to bytes,
        ), asynchronous = true)
        assertTrue(bytes.all { it == 0.toByte() })
        return result
    }

    private fun input(
        bridge: VncNativeBridge,
        binding: Map<String, Any>,
        sequence: Long,
        event: Map<String, Any>,
    ) = invoke(bridge, "input", mapOf(
        "binding" to binding,
        "sequence" to sequence,
        "event" to event,
    ))

    private fun pointer(x: Double, y: Double, buttons: Int) = mapOf(
        "kind" to "pointer",
        "x" to x,
        "y" to y,
        "buttons" to buttons,
    )

    private fun acknowledge(
        bridge: VncNativeBridge,
        binding: Map<String, Any>,
        frame: Map<*, *>,
    ) {
        val result = invoke(bridge, "ackFrame", mapOf(
            "binding" to binding,
            "sequence" to frame["sequence"],
        ))
        assertNull(result.error)
    }

    private fun awaitFrame(
        sink: Sink,
        sessionId: String,
        minimumCount: Int,
        condition: (Map<*, *>) -> Boolean = { true },
    ): Map<*, *> {
        var found: Map<*, *>? = null
        pumpUntil {
            val candidates = synchronized(sink.values) {
                sink.values.filter { it["sessionId"] == sessionId }
            }
            found = candidates.drop(minimumCount - 1).firstOrNull(condition)
            candidates.size >= minimumCount && found != null
        }
        assertNull(sink.error)
        return found!!
    }

    private fun invoke(
        bridge: VncNativeBridge,
        method: String,
        arguments: Any?,
        asynchronous: Boolean = false,
    ): Result {
        val result = Result()
        bridge.onMethodCall(MethodCall(method, arguments), result)
        if (asynchronous) pumpUntil { result.completed }
        else assertTrue("$method did not complete synchronously", result.completed)
        return result
    }

    private fun pumpUntil(condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (!condition() && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue("Timed out waiting for real TigerVNC acceptance", condition())
    }

    private fun binding(routeRevision: Long) = mapOf<String, Any>(
        "ownerId" to "22222222-2222-4222-8222-222222222222",
        "accountRevision" to 7,
        "routeRevision" to routeRevision,
    )

    private fun request(
        host: String,
        port: Int,
        pin: String,
        requestId: String,
        width: Int,
        height: Int,
    ) = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to requestId,
        "targetHost" to host,
        "targetPort" to port,
        "security" to mapOf(
            "type" to "vencryptTlsVncAuth",
            "spkiFingerprint" to pin,
            "requiresPassword" to true,
        ),
        "display" to mapOf(
            "width" to width,
            "height" to height,
            "dpi" to 180,
            "externalDisplay" to false,
            "dynamicResolution" to true,
        ),
        "framebuffer" to mapOf("encoding" to "raw", "pixelFormat" to "trueColor32"),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    )

    private fun requireEnvironment(name: String): String =
        System.getenv(name)?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("Missing required owned TigerVNC fixture value: $name")

    companion object {
        private const val ENABLED = "LARENOR_F61_TIGERVNC_ACCEPTANCE"
        private const val HOST = "LARENOR_F61_TIGERVNC_HOST"
        private const val PORT = "LARENOR_F61_TIGERVNC_PORT"
        private const val PASSWORD = "LARENOR_F61_TIGERVNC_PASSWORD"
    }
}
