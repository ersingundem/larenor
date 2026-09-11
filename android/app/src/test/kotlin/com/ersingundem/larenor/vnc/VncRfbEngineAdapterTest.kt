package com.ersingundem.larenor.vnc

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VncRfbEngineAdapterTest {
    @Test
    fun parserEventsDriveTheExactNativeSessionLifecycleAndAck() {
        val transport = Transport()
        val frames = mutableListOf<VncRfbFrame>()
        val session = VncRfbEngineAdapter().open(rawPlan(), transport) {
            frames += it
            true
        }
        assertEquals(VncRfbEnginePhase.VERSION, session.phase)
        transport.bytes("RFB 003.008\n".encodeToByteArray())
        assertEquals(VncRfbEnginePhase.SECURITY, session.phase)
        transport.bytes(byteArrayOf(1, 19))
        assertEquals(VncRfbEnginePhase.SECURITY_HANDOFF, session.phase)
        transport.secureAuthenticated()
        assertEquals(VncRfbEnginePhase.INITIALIZING, session.phase)
        transport.bytes(serverInit(1280, 800))
        assertEquals(VncRfbEnginePhase.ACTIVE, session.phase)

        transport.bytes(frameUpdate())
        assertEquals(VncRfbEnginePhase.AWAITING_ACK, session.phase)
        assertEquals(listOf(1L), frames.map { it.sequence })
        session.acknowledgeFrame(1)
        assertEquals(VncRfbEnginePhase.ACTIVE, session.phase)
        assertEquals(1, transport.writes.last()[1].toInt())
        assertEquals(0, transport.cancels)
    }

    @Test
    fun malformedBytesAndWrongAckFailClosedOnceAndIgnoreLateCallbacks() {
        val malformedTransport = Transport()
        val malformed = VncRfbEngineAdapter().open(rawPlan(), malformedTransport) { true }
        malformedTransport.bytes("RFB 003.007\n".encodeToByteArray())
        assertEquals(VncRfbEnginePhase.FAILED, malformed.phase)
        assertEquals("rfbVersionUnavailable", malformed.failureCode)
        assertEquals(1, malformedTransport.cancels)
        malformedTransport.bytes("RFB 003.008\n".encodeToByteArray())
        malformedTransport.secureAuthenticated()
        assertEquals(1, malformedTransport.cancels)

        val ackTransport = Transport()
        val ack = activeSession(ackTransport)
        ackTransport.bytes(frameUpdate())
        ack.acknowledgeFrame(2)
        assertEquals(VncRfbEnginePhase.FAILED, ack.phase)
        assertEquals("staleSession", ack.failureCode)
        assertEquals(1, ackTransport.cancels)
    }

    @Test
    fun backgroundAndCloseAreTerminalWithExactCleanup() {
        val transport = Transport()
        var callbacks = 0
        val session = VncRfbEngineAdapter().open(rawPlan(), transport) {
            callbacks++
            true
        }
        transport.bytes("RFB 003.".encodeToByteArray())
        session.setForeground(false)
        assertEquals(VncRfbEnginePhase.CANCELLED, session.phase)
        assertEquals(1, transport.cancels)
        assertEquals(1, transport.detaches)
        session.close()
        transport.bytes("008\n".encodeToByteArray())
        assertEquals(0, callbacks)
        assertEquals(1, transport.cancels)
    }

    @Test
    fun productionBackendRemainsUnavailableWithoutRealTlsAndVencrypt() {
        val adapter = VncNativeAdapter()
        assertFalse(adapter.capabilities().canConnect)
        assertEquals(VncNativeAvailability.UNAVAILABLE, adapter.capabilities().availability)
        assertFalse(VncRfbEngineAdapter.productionAvailable)
    }

    private fun activeSession(transport: Transport): VncRfbEngineSession {
        val session = VncRfbEngineAdapter().open(rawPlan(), transport) { true }
        transport.bytes("RFB 003.008\n".encodeToByteArray())
        transport.bytes(byteArrayOf(1, 19))
        transport.secureAuthenticated()
        transport.bytes(serverInit(1280, 800))
        return session
    }

    private fun rawPlan(): VncNativePlan {
        val request = VncNativeRequest.parse(request())
        return VncNativeNegotiator.negotiate(
            request,
            VncNativeCapabilities.parse(capabilities()),
        )
    }

    private fun capabilities() = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "availability" to "available",
        "engineRevision" to "rfb-synthetic-1",
        "rfbVersions" to listOf("3.8"),
        "securityTypes" to listOf("vencryptTlsVncAuth"),
        "transport" to mapOf("tls" to true, "spkiPinning" to true),
        "auth" to mapOf("password" to true),
        "framebuffer" to mapOf(
            "encodings" to listOf("raw"),
            "trueColor32" to true,
            "dynamicResolution" to true,
            "externalDisplay" to true,
            "maxWidth" to 8192,
            "maxHeight" to 8192,
            "maxDpi" to 640,
        ),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    )

    private fun request() = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to "11111111-1111-4111-8111-111111111111",
        "targetHost" to "fixture.invalid",
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
        "framebuffer" to mapOf("encoding" to "raw", "pixelFormat" to "trueColor32"),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    )

    private fun serverInit(width: Int, height: Int): ByteArray =
        ByteArrayOutputStream().apply {
            u16(width)
            u16(height)
            write(byteArrayOf(
                32, 24, 0, 1,
                0, 0xff.toByte(), 0, 0xff.toByte(), 0, 0xff.toByte(),
                0, 8, 16, 0, 0, 0,
            ))
            val name = "fixture".encodeToByteArray()
            u32(name.size)
            write(name)
        }.toByteArray()

    private fun frameUpdate(): ByteArray = ByteArrayOutputStream().apply {
        write(byteArrayOf(0, 0))
        u16(1)
        u16(0)
        u16(0)
        u16(1)
        u16(1)
        u32(0)
        write(byteArrayOf(1, 2, 3, 0))
    }.toByteArray()

    private fun ByteArrayOutputStream.u16(value: Int) {
        write(byteArrayOf((value ushr 8).toByte(), value.toByte()))
    }

    private fun ByteArrayOutputStream.u32(value: Int) {
        write(byteArrayOf(
            (value ushr 24).toByte(),
            (value ushr 16).toByte(),
            (value ushr 8).toByte(),
            value.toByte(),
        ))
    }

    private class Transport : VncRfbEngineTransport {
        private var listener: VncRfbEngineTransport.Listener? = null
        val writes = mutableListOf<ByteArray>()
        var cancels = 0
        var detaches = 0

        override fun attach(listener: VncRfbEngineTransport.Listener) {
            check(this.listener == null)
            this.listener = listener
        }

        override fun write(bytes: ByteArray): Boolean {
            writes += bytes.copyOf()
            return true
        }

        override fun cancel() { cancels++ }

        override fun detach() {
            detaches++
            listener = null
        }

        fun bytes(value: ByteArray) { listener?.onBytes(value) }
        fun secureAuthenticated() { listener?.onSecureAuthenticated() }
    }
}
