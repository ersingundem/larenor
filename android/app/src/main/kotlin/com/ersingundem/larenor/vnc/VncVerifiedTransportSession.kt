package com.ersingundem.larenor.vnc

internal enum class VncVerifiedTransportPhase {
    CONNECTING,
    ACTIVE,
    CANCELLED,
    TIMED_OUT,
    FAILED,
}

/** Closed failure vocabulary for the future Android transport implementation. */
internal enum class VncVerifiedTransportFailure {
    CONNECTION_FAILED,
    TLS_VERIFICATION_FAILED,
    AUTHENTICATION_FAILED,
    PROTOCOL_FAILED,
}

/**
 * One-use proof produced only by [VncRfbEngineSession] after the complete
 * verified handshake reaches ACTIVE. It contains no host, credential, pin, or
 * framebuffer bytes.
 */
internal class VncVerifiedRfbResult private constructor(
    private val requestId: String,
    private val engineRevision: String,
    private val rfbVersion: String,
    private val securityType: VncSecurityType,
    private val framebufferEncoding: VncFramebufferEncoding,
) : AutoCloseable {
    private var consumed = false

    internal fun consume(expected: VncNativePlan) {
        if (consumed) throw VncNativeFailure("staleSession")
        consumed = true
        if (requestId != expected.requestId ||
            engineRevision != expected.engineRevision ||
            rfbVersion != expected.rfbVersion ||
            securityType != expected.securityType ||
            framebufferEncoding != expected.framebufferEncoding
        ) {
            throw VncNativeFailure("staleSession")
        }
    }

    override fun close() {
        consumed = true
    }

    override fun toString() = "VncVerifiedRfbResult(<redacted>)"

    companion object {
        internal fun issue(session: VncRfbEngineSession): VncVerifiedRfbResult {
            val plan = session.claimVerifiedPlan()
            return VncVerifiedRfbResult(
                requestId = plan.requestId,
                engineRevision = plan.engineRevision,
                rfbVersion = plan.rfbVersion,
                securityType = plan.securityType,
                framebufferEncoding = plan.framebufferEncoding,
            )
        }
    }
}

/**
 * Package-private lifecycle boundary for a future real Android TLS/RFB
 * operation. Implementations must emit exactly one terminal callback and must
 * not restart or replay an operation.
 */
internal interface VncVerifiedTransportOperation {
    interface Listener {
        fun onVerified(result: VncVerifiedRfbResult)
        fun onFailure(failure: VncVerifiedTransportFailure)
        fun onClosed()
    }

    fun attach(listener: Listener)
    fun start(): Boolean
    fun cancel()
    fun detach()
}

/**
 * Accepts only an opaque verified result, binds it to the exact negotiated
 * request, and owns bounded cancellation/lifecycle cleanup. This class opens no
 * socket and is not wired into the packaged backend yet.
 */
internal class VncVerifiedTransportSession(
    private val plan: VncNativePlan,
    private val operation: VncVerifiedTransportOperation,
    deadlineMillis: Long,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
) : VncNativeSession, VncVerifiedTransportOperation.Listener {
    var phase = VncVerifiedTransportPhase.CONNECTING
        private set
    var failureCode: String? = null
        private set

    private val deadlineAt: Long
    private var terminated = false
    private var startInvoked = false

    init {
        if (deadlineMillis !in 1..MAX_DEADLINE_MILLIS) {
            throw VncNativeFailure("invalidRequest")
        }
        val startedAt = nowMillis()
        if (startedAt < 0 || startedAt > Long.MAX_VALUE - deadlineMillis) {
            throw VncNativeFailure("invalidRequest")
        }
        deadlineAt = startedAt + deadlineMillis
        try {
            operation.attach(this)
            if (!terminated) {
                startInvoked = true
                if (!operation.start()) {
                    terminate(VncVerifiedTransportPhase.FAILED, "connectionFailed")
                }
            }
        } catch (_: Exception) {
            terminate(VncVerifiedTransportPhase.FAILED, "connectionFailed")
        }
    }

    override fun onVerified(result: VncVerifiedRfbResult) {
        if (terminated || !startInvoked || phase != VncVerifiedTransportPhase.CONNECTING) {
            result.close()
            if (!terminated && !startInvoked) {
                terminate(VncVerifiedTransportPhase.FAILED, "staleSession")
            }
            return
        }
        if (nowMillis() > deadlineAt) {
            result.close()
            terminate(VncVerifiedTransportPhase.TIMED_OUT, "timedOut")
            return
        }
        try {
            result.consume(plan)
            phase = VncVerifiedTransportPhase.ACTIVE
        } catch (failure: VncNativeFailure) {
            terminate(VncVerifiedTransportPhase.FAILED, failure.code)
        } catch (_: Exception) {
            result.close()
            terminate(VncVerifiedTransportPhase.FAILED, "connectionFailed")
        }
    }

    override fun onFailure(failure: VncVerifiedTransportFailure) {
        if (terminated) return
        val code = when (failure) {
            VncVerifiedTransportFailure.TLS_VERIFICATION_FAILED -> "tlsRequired"
            VncVerifiedTransportFailure.AUTHENTICATION_FAILED -> "authUnavailable"
            VncVerifiedTransportFailure.PROTOCOL_FAILED,
            VncVerifiedTransportFailure.CONNECTION_FAILED,
            -> "connectionFailed"
        }
        terminate(VncVerifiedTransportPhase.FAILED, code)
    }

    override fun onClosed() {
        if (!terminated) terminate(VncVerifiedTransportPhase.FAILED, "connectionFailed")
    }

    fun checkDeadline() {
        if (!terminated && phase == VncVerifiedTransportPhase.CONNECTING && nowMillis() > deadlineAt) {
            terminate(VncVerifiedTransportPhase.TIMED_OUT, "timedOut")
        }
    }

    fun setForeground(foreground: Boolean) {
        if (!foreground) terminate(VncVerifiedTransportPhase.CANCELLED, null)
    }

    override fun close() {
        terminate(VncVerifiedTransportPhase.CANCELLED, null)
    }

    private fun terminate(next: VncVerifiedTransportPhase, code: String?) {
        if (terminated) return
        terminated = true
        phase = next
        failureCode = code
        try {
            operation.detach()
        } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
        try {
            operation.cancel()
        } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
    }

    companion object {
        const val productionAvailable = false
        private const val MAX_DEADLINE_MILLIS = 60_000L
    }
}
