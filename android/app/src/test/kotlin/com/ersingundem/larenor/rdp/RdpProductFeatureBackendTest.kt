package com.ersingundem.larenor.rdp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RdpProductFeatureBackendTest {
    private class RecordedBackend : RdpNativeBackend {
        var opens = 0
        override fun capabilities() = RdpNativeCapabilities.parse(RdpFreeRdpPackage.compiledCapabilities())
        override fun open(
            request: RdpNativeRequest,
            negotiated: RdpNativeNegotiated,
            secrets: RdpNativeSecrets,
            observer: RdpNativeSessionObserver,
        ): RdpNativeSession {
            opens++
            throw RdpNativeFailure("connectionFailed")
        }
    }

    @Test
    fun compiledSupportCannotPublishUnacceptedProductCapabilities() {
        val compiled = RecordedBackend()
        assertTrue(compiled.capabilities().rdGateway && compiled.capabilities().files)
        val product = RdpProductFeatureBackend(compiled).capabilities()
        assertFalse(product.rdGateway || product.files)
        assertTrue(product.canConnect && product.audio && product.microphone)
        assertEquals(compiled.capabilities().engineRevision, product.engineRevision)
        assertEquals(compiled.capabilities().deviceScaleFactors, product.deviceScaleFactors)
        assertEquals(compiled.capabilities().clipboardModes, product.clipboardModes)
        assertEquals(0, compiled.opens)
    }

    @Test
    fun directOwnedOpenCannotBypassAdmissionAndSecretsAreWiped() {
        for ((gateway, files, expected) in listOf(
            Triple(true, false, "gatewayUnavailable"),
            Triple(false, true, "channelUnavailable"),
            Triple(true, true, "gatewayUnavailable"),
        )) {
            val compiled = RecordedBackend()
            val product = RdpProductFeatureBackend(compiled)
            val request = request(gateway, files)
            val password = "target-private".toCharArray()
            val gatewayPassword = if (gateway) "gateway-private".toCharArray() else null
            val secret = RdpNativeSecrets.take(password, gatewayPassword)
            val failure = runCatching {
                RdpNativeAdapter(product).open(request, secret)
            }.exceptionOrNull() as RdpNativeFailure
            assertEquals(expected, failure.code)
            assertEquals(0, compiled.opens)
            assertTrue(secret.closed && password.all { it == '\u0000' })
            assertTrue(gatewayPassword?.all { it == '\u0000' } != false)
            // A plan from the compiled runtime is also rejected by the wrapper itself.
            val plan = RdpNativeNegotiator.negotiate(request, compiled.capabilities())
            val directSecrets = RdpNativeSecrets.take("private".toCharArray(),
                if (gateway) "private-gateway".toCharArray() else null)
            try {
                val directFailure = runCatching {
                    product.open(request, plan, directSecrets, RdpNativeSessionObserver.NONE)
                }.exceptionOrNull() as RdpNativeFailure
                assertEquals(expected, directFailure.code)
                assertEquals(0, compiled.opens)
            } finally { directSecrets.close() }
        }
    }

    @Test
    fun ordinarySchemaFourStillDelegatesToRealBackend() {
        val compiled = RecordedBackend()
        val failure = runCatching {
            RdpNativeAdapter(RdpProductFeatureBackend(compiled)).open(
                request(false, false), RdpNativeSecrets.take("private".toCharArray(), null),
            )
        }.exceptionOrNull() as RdpNativeFailure
        assertEquals("connectionFailed", failure.code)
        assertEquals(1, compiled.opens)
    }

    private fun request(gateway: Boolean, files: Boolean): RdpNativeRequest = RdpNativeRequest.parse(
        mapOf(
            "schemaVersion" to if (gateway || files) 6 else 4,
            "requestId" to "11111111-1111-4111-8111-111111111111",
            "targetHost" to "owned.example.test", "targetPort" to 3389,
            "username" to "target-user", "domain" to "TARGET",
            "certificateFingerprint" to "SHA256:" + "A".repeat(43),
            "requiresNla" to true,
            "gateway" to if (gateway) mapOf(
                "host" to "gateway.example.test", "port" to 443,
                "username" to "gateway-user", "domain" to "GATEWAY",
                "certificateFingerprint" to "SHA256:" + "B".repeat(43),
            ) else null,
            "display" to mapOf(
                "width" to 1280, "height" to 800, "desktopScaleFactor" to 100,
                "deviceScaleFactor" to 100, "externalDisplay" to false, "dynamicResize" to true,
            ),
            "keyboardLayout" to "turkishQ", "clipboardMode" to "disabled",
            "audio" to false, "microphone" to false, "files" to files,
        ) + if (gateway || files) mapOf(
            "sessionRevision" to 9L,
            "fileTransfer" to if (files) mapOf("transferId" to "2".repeat(32)) else null,
        ) else emptyMap<String, Any?>(),
    )
}
