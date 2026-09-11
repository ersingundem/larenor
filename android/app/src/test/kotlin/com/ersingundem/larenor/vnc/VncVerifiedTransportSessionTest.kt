package com.ersingundem.larenor.vnc

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VncVerifiedTransportSessionTest {
    @Test
    fun onlyAnActiveVerifiedRfbResultCanActivateTheNativeSession() {
        var now = 1_000L
        val operation = Operation()
        val plan = rawPlan()
        val session = VncVerifiedTransportSession(
            plan = plan,
            operation = operation,
            deadlineMillis = 10_000,
            nowMillis = { now },
        )
        assertEquals(VncVerifiedTransportPhase.CONNECTING, session.phase)
        assertEquals(1, operation.starts)

        val unverified = VncRfbEngineAdapter().open(plan, RfbTransport()) { true }
        val early = runCatching { unverified.claimVerifiedResult() }.exceptionOrNull() as VncNativeFailure
        assertEquals("staleSession", early.code)
        unverified.close()

        val engine = activeEngine(plan)
        operation.verified(engine.claimVerifiedResult())

        assertEquals(VncVerifiedTransportPhase.ACTIVE, session.phase)
        assertNull(session.failureCode)
        assertEquals(0, operation.cancels)
        assertFalse(VncVerifiedTransportSession.productionAvailable)
        val duplicate = runCatching { engine.claimVerifiedResult() }.exceptionOrNull() as VncNativeFailure
        assertEquals("staleSession", duplicate.code)
    }

    @Test
    fun resultIsBoundToTheExactRequestAndEngineRevisionAndCannotReplay() {
        val operation = Operation()
        val expected = rawPlan(requestId = "11111111-1111-4111-8111-111111111111")
        val other = rawPlan(requestId = "22222222-2222-4222-8222-222222222222")
        val result = activeEngine(other).claimVerifiedResult()
        val session = VncVerifiedTransportSession(expected, operation, 10_000) { 1_000L }

        operation.verified(result)

        assertEquals(VncVerifiedTransportPhase.FAILED, session.phase)
        assertEquals("staleSession", session.failureCode)
        assertEquals(1, operation.cancels)
        assertEquals(1, operation.detaches)

        val replayOperation = Operation()
        val replaySession = VncVerifiedTransportSession(other, replayOperation, 10_000) { 1_000L }
        replayOperation.verified(result)
        assertEquals(VncVerifiedTransportPhase.FAILED, replaySession.phase)
        assertEquals("staleSession", replaySession.failureCode)
        assertEquals(1, replayOperation.cancels)
    }

    @Test
    fun deadlineAndBackgroundCancellationDiscardLateVerificationWithExactCleanup() {
        var now = 500L
        val timeoutOperation = Operation()
        val plan = rawPlan()
        val timed = VncVerifiedTransportSession(plan, timeoutOperation, 2_000) { now }
        now = 2_501L
        timed.checkDeadline()
        assertEquals(VncVerifiedTransportPhase.TIMED_OUT, timed.phase)
        assertEquals("timedOut", timed.failureCode)
        assertEquals(1, timeoutOperation.cancels)
        timeoutOperation.verified(activeEngine(plan).claimVerifiedResult())
        assertEquals(VncVerifiedTransportPhase.TIMED_OUT, timed.phase)
        assertEquals(1, timeoutOperation.cancels)

        val backgroundOperation = Operation()
        val background = VncVerifiedTransportSession(plan, backgroundOperation, 2_000) { 500L }
        background.setForeground(false)
        background.close()
        assertEquals(VncVerifiedTransportPhase.CANCELLED, background.phase)
        assertEquals(1, backgroundOperation.cancels)
        assertEquals(1, backgroundOperation.detaches)
        backgroundOperation.verified(activeEngine(plan).claimVerifiedResult())
        assertEquals(VncVerifiedTransportPhase.CANCELLED, background.phase)
    }

    @Test
    fun transportFailureAndCloseAreRedactedTerminalEventsWithoutRetry() {
        val failedOperation = Operation()
        val failed = VncVerifiedTransportSession(rawPlan(), failedOperation, 10_000) { 0L }
        failedOperation.failed(VncVerifiedTransportFailure.TLS_VERIFICATION_FAILED)
        failedOperation.failed(VncVerifiedTransportFailure.CONNECTION_FAILED)
        assertEquals(VncVerifiedTransportPhase.FAILED, failed.phase)
        assertEquals("tlsRequired", failed.failureCode)
        assertEquals(1, failedOperation.starts)
        assertEquals(1, failedOperation.cancels)

        val closedOperation = Operation()
        val closed = VncVerifiedTransportSession(rawPlan(), closedOperation, 10_000) { 0L }
        closedOperation.closed()
        assertEquals(VncVerifiedTransportPhase.FAILED, closed.phase)
        assertEquals("connectionFailed", closed.failureCode)
        assertEquals(1, closedOperation.starts)
        assertEquals(1, closedOperation.cancels)
    }

    @Test
    fun startFailureAndInvalidDeadlineFailClosedWithoutAutomaticReplay() {
        val rejected = Operation(startAccepted = false)
        val session = VncVerifiedTransportSession(rawPlan(), rejected, 10_000) { 0L }
        assertEquals(VncVerifiedTransportPhase.FAILED, session.phase)
        assertEquals("connectionFailed", session.failureCode)
        assertEquals(1, rejected.starts)
        assertEquals(1, rejected.cancels)

        val invalid = runCatching {
            VncVerifiedTransportSession(rawPlan(), Operation(), 60_001) { 0L }
        }.exceptionOrNull() as VncNativeFailure
        assertEquals("invalidRequest", invalid.code)
    }

    private fun activeEngine(plan: VncNativePlan): VncRfbEngineSession {
        val transport = RfbTransport()
        val engine = VncRfbEngineAdapter().open(plan, transport) { true }
        transport.bytes("RFB 003.008\n".encodeToByteArray())
        transport.bytes(byteArrayOf(1, 19))
        transport.security(byteArrayOf(0, 2))
        transport.security(byteArrayOf(0))
        transport.security(byteArrayOf(1, 0, 0, 1, 5))
        transport.peer(
            VncTlsPeerEvidence.take(
                protocol = "TLSv1.3",
                cipherSuite = "TLS_AES_128_GCM_SHA256",
                certificateChainValid = true,
                hostnameVerified = true,
                spkiSha256 = ByteArray(32),
            ),
        )
        transport.auth(true)
        transport.bytes(serverInit())
        assertEquals(VncRfbEnginePhase.ACTIVE, engine.phase)
        return engine
    }

    private fun rawPlan(requestId: String = "11111111-1111-4111-8111-111111111111"): VncNativePlan =
        VncNativeNegotiator.negotiate(
            VncNativeRequest.parse(request(requestId)),
            VncNativeCapabilities.parse(capabilities()),
        )

    private fun capabilities() = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "availability" to "available",
        "engineRevision" to "rfb-verified-fixture-1",
        "rfbVersions" to listOf("3.8"),
        "securityTypes" to listOf("vencryptTlsVncAuth"),
        "transport" to mapOf("tls" to true, "spkiPinning" to true),
        "auth" to mapOf("password" to true),
        "framebuffer" to mapOf(
            "encodings" to listOf("raw"), "trueColor32" to true,
            "dynamicResolution" to true, "externalDisplay" to true,
            "maxWidth" to 8192, "maxHeight" to 8192, "maxDpi" to 640,
        ),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    )

    private fun request(requestId: String) = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to requestId,
        "targetHost" to "fixture.invalid",
        "targetPort" to 5900,
        "security" to mapOf(
            "type" to "vencryptTlsVncAuth",
            "spkiFingerprint" to "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "requiresPassword" to true,
        ),
        "display" to mapOf(
            "width" to 1280, "height" to 800, "dpi" to 180,
            "externalDisplay" to false, "dynamicResolution" to true,
        ),
        "framebuffer" to mapOf("encoding" to "raw", "pixelFormat" to "trueColor32"),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    )

    private fun serverInit(): ByteArray = ByteArrayOutputStream().apply {
        u16(1280)
        u16(800)
        write(byteArrayOf(
            32, 24, 0, 1,
            0, 0xff.toByte(), 0, 0xff.toByte(), 0, 0xff.toByte(),
            0, 8, 16, 0, 0, 0,
        ))
        val name = "fixture".encodeToByteArray()
        u32(name.size)
        write(name)
    }.toByteArray()

    private fun ByteArrayOutputStream.u16(value: Int) =
        write(byteArrayOf((value ushr 8).toByte(), value.toByte()))

    private fun ByteArrayOutputStream.u32(value: Int) = write(byteArrayOf(
        (value ushr 24).toByte(), (value ushr 16).toByte(),
        (value ushr 8).toByte(), value.toByte(),
    ))

    private class RfbTransport : VncRfbEngineTransport {
        private var listener: VncRfbEngineTransport.Listener? = null
        override fun attach(listener: VncRfbEngineTransport.Listener) { this.listener = listener }
        override fun write(bytes: ByteArray) = true
        override fun cancel() = Unit
        override fun detach() { listener = null }
        fun bytes(bytes: ByteArray) { listener?.onBytes(bytes) }
        fun security(bytes: ByteArray) { listener?.onSecurityBytes(bytes) }
        fun peer(evidence: VncTlsPeerEvidence) { listener?.onTlsPeer(evidence) ?: evidence.close() }
        fun auth(success: Boolean) { listener?.onVncAuthResult(success) }
    }

    private class Operation(
        private val startAccepted: Boolean = true,
    ) : VncVerifiedTransportOperation {
        private var listener: VncVerifiedTransportOperation.Listener? = null
        var starts = 0
        var cancels = 0
        var detaches = 0
        override fun attach(listener: VncVerifiedTransportOperation.Listener) { this.listener = listener }
        override fun start(): Boolean { starts++; return startAccepted }
        override fun cancel() { cancels++ }
        override fun detach() { detaches++; listener = null }
        fun verified(result: VncVerifiedRfbResult) {
            listener?.onVerified(result) ?: result.close()
        }
        fun failed(failure: VncVerifiedTransportFailure) { listener?.onFailure(failure) }
        fun closed() { listener?.onClosed() }
    }
}
