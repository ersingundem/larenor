package com.ersingundem.larenor.rdp

/**
 * Product admission is separate from the compiled AAR's real channel support.
 * There is no successful exact-source Gateway/RDPDR effect receipt admitted yet.
 * Both capability publication and open use this boundary; calling open directly
 * cannot bypass the mask. Packaged instrumentation uses the same real backend
 * without this product wrapper to collect the missing effect evidence.
 */
internal class RdpProductFeatureBackend(private val backend: RdpNativeBackend) : RdpNativeBackend {
    override fun capabilities(): RdpNativeCapabilities {
        val compiled = backend.capabilities().toChannel()
        val security = compiled["security"] as Map<*, *>
        val channels = compiled["channels"] as Map<*, *>
        return RdpNativeCapabilities.parse(compiled + mapOf(
            "security" to (security + ("rdGateway" to false)),
            // The public legacy wire also has a derived clipboard alias; it
            // is deliberately absent from the closed internal capability map.
            "channels" to ((channels - "clipboard") + ("files" to false)),
        ))
    }

    override fun open(
        request: RdpNativeRequest,
        negotiated: RdpNativeNegotiated,
        secrets: RdpNativeSecrets,
        observer: RdpNativeSessionObserver,
    ): RdpNativeSession = open(request, negotiated, secrets, observer, null)

    override fun open(
        request: RdpNativeRequest,
        negotiated: RdpNativeNegotiated,
        secrets: RdpNativeSecrets,
        observer: RdpNativeSessionObserver,
        fileTransfer: RdpNativeFileTransferEndpoint?,
    ): RdpNativeSession {
        // Repeat admission at the delegation boundary, even for a direct caller
        // that supplies a plan negotiated against compiled capabilities.
        val admitted = RdpNativeNegotiator.negotiate(request, capabilities())
        if (negotiated.engineRevision != admitted.engineRevision) {
            throw RdpNativeFailure("engineUnavailable")
        }
        return backend.open(request, admitted, secrets, observer, fileTransfer)
    }
}
