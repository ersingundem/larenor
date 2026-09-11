package com.ersingundem.larenor.vnc

internal enum class VncRfbEnginePhase {
    VERSION,
    SECURITY,
    SECURITY_HANDOFF,
    TLS_HANDOFF,
    AUTHENTICATING,
    INITIALIZING,
    ACTIVE,
    AWAITING_ACK,
    CANCELLED,
    FAILED,
}

/** An injected in-memory byte boundary. It owns no address or network API. */
internal interface VncRfbEngineTransport {
    interface Listener {
        fun onBytes(bytes: ByteArray)
        fun onSecurityBytes(bytes: ByteArray)
        fun onTlsPeer(evidence: VncTlsPeerEvidence)
        fun onVncAuthResult(success: Boolean)
        fun onClosed()
    }

    fun attach(listener: Listener)
    fun write(bytes: ByteArray): Boolean
    fun cancel()
    fun detach()
}

internal class VncRfbEngineAdapter {
    fun open(
        plan: VncNativePlan,
        transport: VncRfbEngineTransport,
        onFrame: (VncRfbFrame) -> Boolean,
    ): VncRfbEngineSession {
        if (plan.rfbVersion != "3.8") throw VncNativeFailure("rfbVersionUnavailable")
        if (plan.securityType != VncSecurityType.VENCRYPT_TLS_VNC_AUTH) {
            throw VncNativeFailure("authUnavailable")
        }
        if (plan.framebufferEncoding != VncFramebufferEncoding.RAW) {
            throw VncNativeFailure("framebufferUnavailable")
        }
        return VncRfbEngineSession(transport, plan, onFrame)
    }

    companion object {
        /** Remains false until a separately reviewed TLS/VeNCrypt engine exists. */
        const val productionAvailable = false
    }
}

internal class VncRfbEngineSession(
    private val transport: VncRfbEngineTransport,
    private val plan: VncNativePlan,
    private val onFrame: (VncRfbFrame) -> Boolean,
) : VncNativeSession, VncRfbEngineTransport.Listener {
    var phase = VncRfbEnginePhase.VERSION
        private set
    var failureCode: String? = null
        private set

    private val parser = VncSyntheticRfbParser()
    private val security = VncSyntheticVencrypt(plan.spkiFingerprint)
    private var pendingFrameSequence: Long? = null
    private var verificationIssued = false
    private var terminated = false

    init {
        try {
            transport.attach(this)
        } catch (_: Exception) {
            terminate(VncRfbEnginePhase.FAILED, "connectionFailed")
        }
    }

    override fun onBytes(bytes: ByteArray) {
        if (terminated) return
        try {
            handle(parser.accept(bytes))
            synchronizePhase()
        } catch (error: VncRfbFailure) {
            fail(mapFailure(error.code))
        } catch (_: Exception) {
            fail("connectionFailed")
        }
    }

    override fun onSecurityBytes(bytes: ByteArray) {
        if (terminated) return
        try {
            if (phase != VncRfbEnginePhase.SECURITY_HANDOFF) {
                throw VncVencryptFailure("malformedSecurity")
            }
            for (event in security.accept(bytes)) send(event)
            synchronizeSecurityPhase()
        } catch (error: VncVencryptFailure) {
            fail(mapSecurityFailure(error.code))
        } catch (_: Exception) {
            fail("connectionFailed")
        }
    }

    override fun onTlsPeer(evidence: VncTlsPeerEvidence) {
        if (terminated) {
            evidence.close()
            return
        }
        try {
            if (phase != VncRfbEnginePhase.TLS_HANDOFF) {
                throw VncVencryptFailure("tlsEvidenceInvalid")
            }
            security.verifyPeer(evidence)
            synchronizeSecurityPhase()
        } catch (error: VncVencryptFailure) {
            fail(mapSecurityFailure(error.code))
        } catch (_: Exception) {
            evidence.close()
            fail("connectionFailed")
        }
    }

    override fun onVncAuthResult(success: Boolean) {
        if (terminated) return
        try {
            if (phase != VncRfbEnginePhase.AUTHENTICATING) {
                throw VncVencryptFailure("authFailed")
            }
            security.completeVncAuth(success)
            handle(parser.markSecureAuthenticated())
            synchronizePhase()
        } catch (error: VncVencryptFailure) {
            fail(mapSecurityFailure(error.code))
        } catch (error: VncRfbFailure) {
            fail(mapFailure(error.code))
        } catch (_: Exception) {
            fail("connectionFailed")
        }
    }

    override fun onClosed() {
        if (!terminated) fail("connectionFailed")
    }

    fun acknowledgeFrame(sequence: Long) {
        if (terminated) return
        try {
            if (phase != VncRfbEnginePhase.AWAITING_ACK ||
                pendingFrameSequence != sequence
            ) {
                throw VncRfbFailure("staleFrame")
            }
            send(parser.acknowledgeFrame(sequence))
            pendingFrameSequence = null
            phase = VncRfbEnginePhase.ACTIVE
        } catch (error: VncRfbFailure) {
            fail(mapFailure(error.code))
        } catch (_: Exception) {
            fail("connectionFailed")
        }
    }

    fun setForeground(foreground: Boolean) {
        if (!foreground) terminate(VncRfbEnginePhase.CANCELLED, null)
    }

    /**
     * Produces the package-private, one-use handoff only after the complete
     * RFB + VeNCrypt + TLS/SPKI + VNC-auth + ServerInit chain is active.
     */
    fun claimVerifiedResult(): VncVerifiedRfbResult {
        return VncVerifiedRfbResult.issue(this)
    }

    internal fun claimVerifiedPlan(): VncNativePlan {
        if (terminated || phase != VncRfbEnginePhase.ACTIVE || verificationIssued) {
            throw VncNativeFailure("staleSession")
        }
        verificationIssued = true
        return plan
    }

    override fun close() {
        terminate(VncRfbEnginePhase.CANCELLED, null)
    }

    private fun handle(events: List<VncRfbEvent>) {
        for (event in events) {
            when (event) {
                is VncRfbOutbound -> send(event)
                is VncRfbReady -> {
                    if (phase != VncRfbEnginePhase.INITIALIZING) {
                        throw VncRfbFailure("malformedProtocol")
                    }
                    phase = VncRfbEnginePhase.ACTIVE
                }
                is VncRfbFrame -> {
                    if (phase != VncRfbEnginePhase.ACTIVE || pendingFrameSequence != null) {
                        throw VncRfbFailure("frameBackpressure")
                    }
                    if (!onFrame(event)) throw VncRfbFailure("frameBackpressure")
                    pendingFrameSequence = event.sequence
                    phase = VncRfbEnginePhase.AWAITING_ACK
                }
            }
        }
    }

    private fun send(event: VncRfbOutbound) {
        if (!transport.write(event.bytes)) throw VncRfbFailure("connectionFailed")
    }

    private fun send(event: VncVencryptOutbound) {
        if (!transport.write(event.bytes)) throw VncVencryptFailure("malformedSecurity")
    }

    private fun synchronizePhase() {
        if (phase == VncRfbEnginePhase.AWAITING_ACK || terminated) return
        phase = when (parser.phase) {
            VncRfbPhase.VERSION -> VncRfbEnginePhase.VERSION
            VncRfbPhase.SECURITY_TYPES -> VncRfbEnginePhase.SECURITY
            VncRfbPhase.VENCRYPT_HANDOFF -> VncRfbEnginePhase.SECURITY_HANDOFF
            VncRfbPhase.SERVER_INIT -> VncRfbEnginePhase.INITIALIZING
            VncRfbPhase.ACTIVE -> VncRfbEnginePhase.ACTIVE
            VncRfbPhase.CANCELLED -> VncRfbEnginePhase.CANCELLED
            VncRfbPhase.FAILED -> VncRfbEnginePhase.FAILED
        }
    }

    private fun synchronizeSecurityPhase() {
        if (terminated) return
        phase = when (security.phase) {
            VncVencryptPhase.VERSION,
            VncVencryptPhase.STATUS,
            VncVencryptPhase.SUBTYPES,
            -> VncRfbEnginePhase.SECURITY_HANDOFF
            VncVencryptPhase.TLS_HANDOFF -> VncRfbEnginePhase.TLS_HANDOFF
            VncVencryptPhase.VNC_AUTH_HANDOFF -> VncRfbEnginePhase.AUTHENTICATING
            VncVencryptPhase.AUTHENTICATED -> VncRfbEnginePhase.INITIALIZING
            VncVencryptPhase.CANCELLED -> VncRfbEnginePhase.CANCELLED
            VncVencryptPhase.FAILED -> VncRfbEnginePhase.FAILED
        }
    }

    private fun fail(code: String) {
        terminate(VncRfbEnginePhase.FAILED, code)
    }

    private fun terminate(next: VncRfbEnginePhase, code: String?) {
        if (terminated) return
        terminated = true
        pendingFrameSequence = null
        failureCode = code
        phase = next
        parser.cancel()
        security.cancel()
        try {
            transport.detach()
        } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
        try {
            transport.cancel()
        } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
    }

    private fun mapFailure(code: String): String = when (code) {
        "rfbVersionUnavailable" -> "rfbVersionUnavailable"
        "securityUnavailable" -> "authUnavailable"
        "frameTooLarge", "framebufferUnavailable", "malformedFrame" ->
            "framebufferUnavailable"
        "frameBackpressure", "staleFrame" -> "staleSession"
        "cancelled" -> "cancelled"
        else -> "connectionFailed"
    }

    private fun mapSecurityFailure(code: String): String = when (code) {
        "pinMismatch" -> "spkiPinningRequired"
        "versionUnavailable", "subtypeUnavailable", "authFailed" -> "authUnavailable"
        "tlsEvidenceInvalid" -> "tlsRequired"
        "cancelled" -> "cancelled"
        else -> "connectionFailed"
    }
}
