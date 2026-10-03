package com.ersingundem.larenor.rdp.packaged

import com.ersingundem.larenor.rdp.RdpJniSecurity
import com.ersingundem.larenor.rdp.RdpNativeGateway
import com.ersingundem.larenor.rdp.RdpFreeRdpPackage

private const val CERTIFICATE_FLAG_LEGACY = 0x02L
private const val CERTIFICATE_FLAG_REDIRECT = 0x10L
private const val CERTIFICATE_FLAG_GATEWAY = 0x20L
private const val CERTIFICATE_FLAG_CHANGED = 0x40L
private const val CERTIFICATE_FLAG_MISMATCH = 0x80L
private const val CERTIFICATE_FLAG_MATCH_LEGACY_SHA1 = 0x100L
private const val CERTIFICATE_FLAG_FP_IS_PEM = 0x200L
private const val CERTIFICATE_ALLOWED_FLAGS =
    CERTIFICATE_FLAG_LEGACY or CERTIFICATE_FLAG_GATEWAY or
        CERTIFICATE_FLAG_MISMATCH or CERTIFICATE_FLAG_MATCH_LEGACY_SHA1 or
        CERTIFICATE_FLAG_FP_IS_PEM

/**
 * Binds the two TLS peers of an RD Gateway session without allowing one pin to
 * authorize the other. A successful certificate callback is staged evidence;
 * the target OnConnectionSuccess callback remains the NLA/session authority.
 */
internal class RdpPackagedGatewaySecurityGate(
    private val targetHost: String,
    private val targetPort: Int,
    private val targetPin: String,
    private val gateway: RdpNativeGateway?,
) {
    private var targetAccepted = false
    private var gatewayAccepted = false
    private var authenticated = false
    private var delivered = false
    private var closed = false

    @Synchronized fun certificate(
        host: String,
        port: Long,
        flags: Long,
        pin: String?,
    ): Boolean {
        if (closed || authenticated || pin == null ||
            flags and (CERTIFICATE_FLAG_REDIRECT or CERTIFICATE_FLAG_CHANGED) != 0L ||
            flags and CERTIFICATE_ALLOWED_FLAGS.inv() != 0L) {
            close()
            return false
        }
        val isGateway = flags and CERTIFICATE_FLAG_GATEWAY != 0L
        if (isGateway) {
            val expected = gateway
            if (expected == null || host != expected.host || port != expected.port.toLong() ||
                pin != expected.certificateFingerprint) {
                close()
                return false
            }
            gatewayAccepted = true
        } else {
            if (host != targetHost || port != targetPort.toLong() || pin != targetPin) {
                close()
                return false
            }
            targetAccepted = true
        }
        return true
    }

    /** Called only by the native successful-connection callback after target NLA. */
    @Synchronized fun connectionSucceeded(): RdpJniSecurity? {
        if (closed || authenticated || !targetAccepted ||
            gateway != null && !gatewayAccepted) return null
        authenticated = true
        return RdpJniSecurity(
            minimumTlsProtocol = RdpFreeRdpPackage.TLS_PROTOCOL,
            nla = true,
            certificateFingerprint = targetPin,
            gatewayCertificatePinned = gateway != null,
        )
    }

    /** Gateway credentials are unavailable until that exact TLS peer is pinned. */
    @Synchronized fun canProvideGatewayCredentials(): Boolean =
        !closed && !authenticated && gateway != null && gatewayAccepted

    /** Target credentials are unavailable until every configured TLS peer is pinned. */
    @Synchronized fun canProvideTargetCredentials(): Boolean =
        !closed && !authenticated && targetAccepted && (gateway == null || gatewayAccepted)

    @Synchronized fun securityDelivered(): Boolean {
        if (closed || !authenticated || delivered) return false
        delivered = true
        return true
    }

    @Synchronized fun canDeliverFrames(): Boolean =
        !closed && authenticated && delivered

    @Synchronized fun close() {
        closed = true
        targetAccepted = false
        gatewayAccepted = false
    }
}
