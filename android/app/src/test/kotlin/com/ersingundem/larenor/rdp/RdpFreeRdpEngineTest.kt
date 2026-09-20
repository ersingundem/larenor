package com.ersingundem.larenor.rdp

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RdpFreeRdpEngineTest {
    @Test
    fun tlsNlaAndExactCertificateGateTheActiveSession() {
        for ((evidence, expected) in listOf(
            RdpJniSecurity("TLSv1.1", true, PIN) to "tlsRequired",
            RdpJniSecurity("TLSv1.3", false, PIN) to "nlaUnavailable",
            RdpJniSecurity("TLSv1.3", true, OTHER_PIN) to "certificatePinningRequired",
        )) {
            val fixture = Fixture()
            val session = fixture.open()
            fixture.operation.secure(evidence)
            assertEquals(RdpJniPhase.FAILED, session.phase)
            assertEquals(expected, session.failureCode)
            assertEquals(1, fixture.operation.closes)
            assertFalse(session.pointer(1, .5, .5, 0))
            fixture.operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
            assertEquals(RdpJniPhase.FAILED, session.phase)
        }

        val fixture = Fixture()
        val session = fixture.open()
        fixture.operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
        assertEquals(RdpJniPhase.ACTIVE, session.phase)
        assertNull(session.failureCode)
    }

    @Test
    fun framebufferAndDexResizeAreBoundedAndRequireOneFrameAck() {
        val acknowledgedFixture = Fixture()
        val acknowledged = acknowledgedFixture.active()
        acknowledgedFixture.operation.frame(frame(1, 1280, 800, 180))
        assertTrue(acknowledged.acknowledgeFrame(1))
        assertEquals(RdpJniPhase.ACTIVE, acknowledged.phase)
        assertEquals(1, acknowledgedFixture.operation.resumes)

        val fixture = Fixture()
        val session = fixture.active()
        val first = frame(1, 1280, 800, 180)
        fixture.operation.frame(first)
        assertEquals(RdpJniPhase.AWAITING_FRAME_ACK, session.phase)
        assertEquals(1L, session.pendingFrame?.sequence)
        assertTrue(session.pointer(1, .5, .5, 0))
        assertEquals(RdpJniPhase.AWAITING_FRAME_ACK, session.phase)

        val rejected = frame(2, 1280, 800, 180)
        fixture.operation.frame(rejected)
        assertEquals("frameBackpressure", session.failureCode)
        assertTrue(rejected.closed)
        assertEquals(1, fixture.operation.closes)

        val resizeFixture = Fixture()
        val resized = resizeFixture.active()
        assertTrue(resized.resize(1, RdpNativeDisplay(2560, 1440, 220, true, true)))
        assertEquals(1, resizeFixture.operation.resizes)
        assertFalse(resized.resize(2, RdpNativeDisplay(8192, 8192, 220, true, true)))
        assertEquals("displayUnavailable", resized.failureCode)
        assertEquals(1, resizeFixture.operation.resizes)
    }

    @Test
    fun pointerKeyboardImeAndChannelsRequireSequencePermissionAndLiveOwnership() {
        val fixture = Fixture(clipboard = RdpClipboardMode.CLIENT_TO_REMOTE)
        val session = fixture.active()
        assertTrue(session.pointer(1, .25, .75, 1))
        assertTrue(session.key(2, 0x70004, true))
        assertTrue(session.ime(3, "İstanbul"))
        assertTrue(session.channel(4, RdpJniChannel.CLIPBOARD, "metin".encodeToByteArray()))
        assertFalse(session.channel(5, RdpJniChannel.AUDIO, byteArrayOf(1)))
        assertEquals("channelUnavailable", session.failureCode)
        assertEquals(4, fixture.operation.inputs)

        val sequenceFixture = Fixture()
        val sequenced = sequenceFixture.active()
        assertFalse(sequenced.pointer(2, .5, .5, 0))
        assertEquals("staleSession", sequenced.failureCode)
        assertEquals(0, sequenceFixture.operation.inputs)
    }

    @Test
    fun disconnectClearsFrameAndNeverReplaysInputOrReconnects() {
        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800, 180))
        fixture.operation.disconnected()
        assertEquals(RdpJniPhase.FAILED, session.phase)
        assertEquals("connectionFailed", session.failureCode)
        assertNull(session.pendingFrame)
        assertEquals(1, fixture.operation.starts)
        assertEquals(1, fixture.operation.closes)
        assertFalse(session.key(1, 42, true))
        fixture.operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
        assertEquals(1, fixture.operation.starts)
    }

    private class Fixture(
        private val clipboard: RdpClipboardMode = RdpClipboardMode.DISABLED,
    ) {
        lateinit var operation: Operation
        private val runtime = object : RdpJniRuntime {
            override fun identity() = RdpFreeRdpIdentity(
                RdpFreeRdpPackage.VERSION,
                RdpFreeRdpPackage.SOURCE_COMMIT,
                RdpFreeRdpPackage.SOURCE_SHA256,
                "x86_64",
                1,
                emptySet(),
            )
            override fun capabilities() = availableCapabilities()
            override fun create(
                request: RdpNativeRequest,
                plan: RdpNativeNegotiated,
                listener: RdpJniOperation.Listener,
            ) = Operation(listener).also { operation = it }
        }

        fun open(): RdpFreeRdpSession {
            val request = RdpNativeRequest.parse(request(clipboard))
            return RdpNativeAdapter(RdpFreeRdpBackend(runtime)).open(
                request,
                RdpNativeSecrets.take("secret".toCharArray(), null),
            ) as RdpFreeRdpSession
        }

        fun active(): RdpFreeRdpSession = open().also {
            operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
        }
    }

    private class Operation(private var listener: RdpJniOperation.Listener?) : RdpJniOperation {
        var starts = 0
        var closes = 0
        var inputs = 0
        var resizes = 0
        var resumes = 0
        override fun start(password: CharArray, gatewayPassword: CharArray?): Boolean {
            starts++
            return true
        }
        override fun input(sequence: Long, event: RdpJniInput): Boolean {
            inputs++
            return true
        }
        override fun resize(sequence: Long, display: RdpNativeDisplay): Boolean {
            resizes++
            return true
        }
        override fun acknowledgeFrame(sequence: Long): Boolean = true
        override fun resumeFrames(): Boolean { resumes++; return true }
        override fun close() { closes++ }
        override fun detach() { listener = null }
        fun secure(value: RdpJniSecurity) { listener?.onSecurity(value) }
        fun frame(value: RdpNativeFrame) { listener?.onFrame(value) ?: value.close() }
        fun disconnected() { listener?.onDisconnected() }
    }

    companion object {
        private const val PIN = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        private const val OTHER_PIN = "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

        fun availableCapabilities() = mapOf<String, Any?>(
            "schemaVersion" to 1,
            "availability" to "available",
            "engineRevision" to RdpFreeRdpPackage.ENGINE_REVISION,
            "security" to mapOf("tls" to true, "certificatePinning" to true, "nla" to true, "rdGateway" to false),
            "display" to mapOf("dynamicResolution" to true, "externalDisplay" to true, "maxWidth" to 4096, "maxHeight" to 2160, "maxDpi" to 480),
            "input" to mapOf("pointer" to true, "keyboard" to true, "ime" to true),
            "channels" to mapOf("clipboardModes" to listOf("disabled", "clientToRemote"), "audio" to false, "files" to false),
        )

        fun request(clipboard: RdpClipboardMode = RdpClipboardMode.DISABLED) = mapOf<String, Any?>(
            "schemaVersion" to 1,
            "requestId" to "11111111-1111-4111-8111-111111111111",
            "targetHost" to "fixture.invalid",
            "targetPort" to 3389,
            "username" to "fixture",
            "domain" to "TEST",
            "gateway" to null,
            "certificateFingerprint" to PIN,
            "requiresNla" to true,
            "display" to mapOf("width" to 1280, "height" to 800, "dpi" to 180, "externalDisplay" to false, "dynamicResize" to true),
            "keyboardLayout" to "turkishQ",
            "clipboardMode" to when (clipboard) {
                RdpClipboardMode.DISABLED -> "disabled"
                RdpClipboardMode.CLIENT_TO_REMOTE -> "clientToRemote"
                RdpClipboardMode.BIDIRECTIONAL -> "bidirectional"
            },
            "audio" to false,
            "files" to false,
        )

        fun frame(sequence: Long, width: Int, height: Int, dpi: Int): RdpNativeFrame {
            val bytes = ByteBuffer.allocateDirect(width * height * 4)
            return RdpNativeFrame.take(sequence, width, height, width * 4, dpi, bytes)
        }
    }
}
