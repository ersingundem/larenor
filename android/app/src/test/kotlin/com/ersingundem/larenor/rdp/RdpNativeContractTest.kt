package com.ersingundem.larenor.rdp

import org.junit.Assert.*
import org.junit.Test

class RdpNativeContractTest {
    private fun available() = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "availability" to "available",
        "engineRevision" to "freerdp-fixture-1",
        "security" to mapOf("tls" to true, "certificatePinning" to true, "nla" to true, "rdGateway" to true),
        "display" to mapOf("dynamicResolution" to true, "externalDisplay" to true, "maxWidth" to 8192, "maxHeight" to 8192, "maxDpi" to 640),
        "input" to mapOf("pointer" to true, "keyboard" to true),
        "channels" to mapOf("clipboardModes" to listOf("disabled", "clientToRemote", "bidirectional")),
    )

    private fun request(overrides: Map<String, Any?> = emptyMap()) = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to "11111111-1111-4111-8111-111111111111",
        "targetHost" to "desktop.home.arpa",
        "targetPort" to 3389,
        "username" to "ersin",
        "domain" to "LARENOR",
        "gateway" to mapOf("host" to "gateway.home.arpa", "port" to 443, "username" to "gateway-user"),
        "certificateFingerprint" to "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "requiresNla" to true,
        "display" to mapOf("width" to 2560, "height" to 1600, "dpi" to 220, "externalDisplay" to true, "dynamicResize" to true),
        "keyboardLayout" to "turkishQ",
        "clipboardMode" to "clientToRemote",
    ) + overrides

    private fun reject(code: String, action: () -> Unit) {
        try {
            action()
            fail("Expected $code")
        } catch (failure: RdpNativeFailure) {
            assertEquals(code, failure.code)
            assertEquals("RdpNativeFailure($code)", failure.toString())
            assertFalse(failure.publicDetails().values.any { it.toString().contains("home.arpa") })
        }
    }

    @Test fun strictCapabilitiesRejectUnknownAndInconsistentClaims() {
        val parsed = RdpNativeCapabilities.parse(available())
        assertTrue(parsed.canConnect)
        assertEquals(setOf(RdpClipboardMode.DISABLED, RdpClipboardMode.CLIENT_TO_REMOTE, RdpClipboardMode.BIDIRECTIONAL), parsed.clipboardModes)
        reject("invalidCapabilities") { RdpNativeCapabilities.parse(available() + ("future" to true)) }
        reject("invalidCapabilities") {
            RdpNativeCapabilities.parse(available() + ("availability" to "unavailable"))
        }
        val unavailable = UnavailableRdpNativeBackend().capabilities()
        assertFalse(unavailable.canConnect)
        assertNull(unavailable.engineRevision)
    }

    @Test fun requestKeepsTargetGatewayAndPolicyStrictWithoutSecrets() {
        val parsed = RdpNativeRequest.parse(request())
        assertEquals("desktop.home.arpa", parsed.targetHost)
        assertEquals("gateway.home.arpa", parsed.gateway?.host)
        assertEquals(RdpKeyboardLayout.TURKISH_Q, parsed.keyboardLayout)
        assertEquals(RdpClipboardMode.CLIENT_TO_REMOTE, parsed.clipboardMode)
        assertFalse(parsed.toString().contains("desktop.home.arpa"))
        assertFalse(parsed.publicSummary().keys.any { it in setOf("targetHost", "username", "domain", "gateway", "certificateFingerprint", "password") })
        for (host in listOf("https://desktop.home.arpa", "user:pass@host", "host:3389", "host/path", "bad host", "bad\nheader")) {
            reject("invalidRequest") { RdpNativeRequest.parse(request(mapOf("targetHost" to host))) }
        }
        reject("invalidRequest") { RdpNativeRequest.parse(request(mapOf("targetPort" to 0))) }
        reject("invalidRequest") { RdpNativeRequest.parse(request(mapOf("password" to "secret"))) }
    }

    @Test fun negotiationFailsClosedInsteadOfDowngradingFeatures() {
        val parsed = RdpNativeRequest.parse(request())
        val negotiated = RdpNativeNegotiator.negotiate(parsed, RdpNativeCapabilities.parse(available()))
        assertEquals("freerdp-fixture-1", negotiated.engineRevision)
        assertEquals(RdpClipboardMode.CLIENT_TO_REMOTE, negotiated.clipboardMode)
        assertFalse(negotiated.toMap().values.any { it.toString().contains("home.arpa") })
        val cases = listOf(
            "tlsRequired" to mapOf("security" to mapOf("tls" to false, "certificatePinning" to true, "nla" to true, "rdGateway" to true)),
            "certificatePinningRequired" to mapOf("security" to mapOf("tls" to true, "certificatePinning" to false, "nla" to true, "rdGateway" to true)),
            "nlaUnavailable" to mapOf("security" to mapOf("tls" to true, "certificatePinning" to true, "nla" to false, "rdGateway" to true)),
            "gatewayUnavailable" to mapOf("security" to mapOf("tls" to true, "certificatePinning" to true, "nla" to true, "rdGateway" to false)),
            "displayUnavailable" to mapOf("display" to mapOf("dynamicResolution" to false, "externalDisplay" to true, "maxWidth" to 8192, "maxHeight" to 8192, "maxDpi" to 640)),
            "clipboardUnavailable" to mapOf("channels" to mapOf("clipboardModes" to listOf("disabled"))),
        )
        for ((code, override) in cases) {
            reject(code) {
                RdpNativeNegotiator.negotiate(parsed, RdpNativeCapabilities.parse(available() + override))
            }
        }
    }

    @Test fun secretsAreMutableBoundedRedactedAndZeroized() {
        val password = "rdp-secret".toCharArray()
        val gateway = "gateway-secret".toCharArray()
        val secrets = RdpNativeSecrets.take(password, gateway)
        assertEquals("RdpNativeSecrets(<redacted>)", secrets.toString())
        assertFalse(secrets.publicSummary().containsValue("rdp-secret"))
        secrets.close()
        assertTrue(password.all { it == '\u0000' })
        assertTrue(gateway.all { it == '\u0000' })
        reject("invalidSecrets") { RdpNativeSecrets.take(CharArray(4097) { 'x' }, null) }
    }

    @Test fun unavailableAdapterNeverLoadsOrConnectsAndErrorsStayClosed() {
        val backend = UnavailableRdpNativeBackend()
        val adapter = RdpNativeAdapter(backend)
        assertFalse(adapter.capabilities().canConnect)
        val secret = RdpNativeSecrets.take("secret".toCharArray(), null)
        reject("engineUnavailable") {
            adapter.open(RdpNativeRequest.parse(request(mapOf("gateway" to null))), secret)
        }
        assertEquals(0, backend.openCalls)
        assertTrue(secret.closed)
        assertEquals(setOf("code", "retryable"), RdpNativeFailure("timedOut").publicDetails().keys)
        reject("invalidFailure") { RdpNativeFailure("raw java.net error: desktop.home.arpa") }
    }
}
