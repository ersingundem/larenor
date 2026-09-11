package com.ersingundem.larenor.vnc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class VncNativeContractTest {
    private fun capabilities(overrides: Map<String, Any?> = emptyMap()) = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "availability" to "available",
        "engineRevision" to "rfb-fixture-1",
        "rfbVersions" to listOf("3.8"),
        "securityTypes" to listOf("vencryptTlsVncAuth"),
        "transport" to mapOf("tls" to true, "spkiPinning" to true),
        "auth" to mapOf("password" to true),
        "framebuffer" to mapOf(
            "encodings" to listOf("tight", "zrle", "raw"),
            "trueColor32" to true,
            "dynamicResolution" to true,
            "externalDisplay" to true,
            "maxWidth" to 8192,
            "maxHeight" to 8192,
            "maxDpi" to 640,
        ),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    ) + overrides

    private fun request(overrides: Map<String, Any?> = emptyMap()) = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to "11111111-1111-4111-8111-111111111111",
        "targetHost" to "desktop.home.arpa",
        "targetPort" to 5900,
        "security" to mapOf(
            "type" to "vencryptTlsVncAuth",
            "spkiFingerprint" to "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "requiresPassword" to true,
        ),
        "display" to mapOf(
            "width" to 2560,
            "height" to 1600,
            "dpi" to 220,
            "externalDisplay" to true,
            "dynamicResolution" to true,
        ),
        "framebuffer" to mapOf("encoding" to "tight", "pixelFormat" to "trueColor32"),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    ) + overrides

    private fun reject(code: String, action: () -> Unit) {
        try {
            action()
            fail("Expected $code")
        } catch (failure: VncNativeFailure) {
            assertEquals(code, failure.code)
            assertEquals(mapOf("code" to code, "retryable" to false), failure.publicDetails())
            assertFalse(failure.toString().contains("home.arpa"))
        }
    }

    @Test
    fun strictCapabilitiesRejectUnknownAndInconsistentClaims() {
        val parsed = VncNativeCapabilities.parse(capabilities())
        assertTrue(parsed.canConnect)
        assertEquals(setOf(VncFramebufferEncoding.TIGHT, VncFramebufferEncoding.ZRLE, VncFramebufferEncoding.RAW), parsed.encodings)
        reject("invalidCapabilities") { VncNativeCapabilities.parse(capabilities() + ("future" to true)) }
        reject("invalidCapabilities") {
            VncNativeCapabilities.parse(capabilities(mapOf("availability" to "unavailable")))
        }
        val unavailable = UnavailableVncNativeBackend().capabilities()
        assertFalse(unavailable.canConnect)
        assertNull(unavailable.engineRevision)
    }

    @Test
    fun requestBoundsIndependentTargetDisplayFramebufferAndInput() {
        val parsed = VncNativeRequest.parse(request())
        assertEquals("desktop.home.arpa", parsed.targetHost)
        assertEquals(5900, parsed.targetPort)
        assertEquals(VncFramebufferEncoding.TIGHT, parsed.framebufferEncoding)
        assertFalse(parsed.toString().contains("desktop.home.arpa"))
        assertFalse(parsed.publicSummary().keys.any { it in setOf("targetHost", "spkiFingerprint", "password") })
        for (host in listOf("https://desktop.home.arpa", "user@host", "host:5900", "host/path", "bad host", "bad\nheader")) {
            reject("invalidRequest") { VncNativeRequest.parse(request(mapOf("targetHost" to host))) }
        }
        reject("invalidRequest") { VncNativeRequest.parse(request(mapOf("targetPort" to 0))) }
        reject("invalidRequest") { VncNativeRequest.parse(request(mapOf("password" to "secret"))) }
    }

    @Test
    fun negotiationRequiresRfb38TlsSpkiAndPasswordAuthWithoutDowngrade() {
        val parsed = VncNativeRequest.parse(request())
        val plan = VncNativeNegotiator.negotiate(parsed, VncNativeCapabilities.parse(capabilities()))
        assertEquals("3.8", plan.rfbVersion)
        assertEquals(VncSecurityType.VENCRYPT_TLS_VNC_AUTH, plan.securityType)
        assertEquals(VncFramebufferEncoding.TIGHT, plan.framebufferEncoding)
        assertFalse(plan.toMap().values.any { it.toString().contains("SHA256:" ) })
        val cases = listOf(
            "tlsRequired" to mapOf("transport" to mapOf("tls" to false, "spkiPinning" to true)),
            "spkiPinningRequired" to mapOf("transport" to mapOf("tls" to true, "spkiPinning" to false)),
            "authUnavailable" to mapOf("auth" to mapOf("password" to false)),
            "framebufferUnavailable" to mapOf(
                "framebuffer" to (capabilities()["framebuffer"] as Map<*, *>).toMutableMap().apply {
                    this["encodings"] = listOf("raw")
                },
            ),
            "inputUnavailable" to mapOf("input" to mapOf("pointer" to true, "keyboard" to false, "clipboard" to false)),
        )
        for ((code, override) in cases) {
            reject(code) {
                VncNativeNegotiator.negotiate(parsed, VncNativeCapabilities.parse(capabilities(override)))
            }
        }
    }

    @Test
    fun plaintextNoAuthAndClipboardEscalationFailClosed() {
        val plain = request(mapOf("security" to mapOf(
            "type" to "vncAuth",
            "spkiFingerprint" to null,
            "requiresPassword" to true,
        )))
        reject("invalidRequest") { VncNativeRequest.parse(plain) }
        val noAuth = request(mapOf("security" to mapOf(
            "type" to "none",
            "spkiFingerprint" to null,
            "requiresPassword" to false,
        )))
        reject("invalidRequest") { VncNativeRequest.parse(noAuth) }
        val clipboard = VncNativeRequest.parse(request(mapOf(
            "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to true),
        )))
        reject("inputUnavailable") {
            VncNativeNegotiator.negotiate(clipboard, VncNativeCapabilities.parse(capabilities()))
        }
    }

    @Test
    fun passwordsAreMutableBoundedRedactedAndAlwaysZeroized() {
        val bytes = "vnc-secret".toCharArray()
        val secrets = VncNativeSecrets.take(bytes)
        assertEquals("VncNativeSecrets(<redacted>)", secrets.toString())
        assertFalse(secrets.publicSummary().containsValue("vnc-secret"))
        secrets.close()
        assertTrue(bytes.all { it == '\u0000' })
        reject("invalidSecrets") { VncNativeSecrets.take(CharArray(4097) { 'x' }) }
    }

    @Test
    fun unavailableDefaultNeverOpensAndUnexpectedErrorsStayRedacted() {
        val backend = UnavailableVncNativeBackend()
        val adapter = VncNativeAdapter(backend)
        assertFalse(adapter.capabilities().canConnect)
        val secrets = VncNativeSecrets.take("secret".toCharArray())
        reject("engineUnavailable") {
            adapter.open(VncNativeRequest.parse(request()), secrets)
        }
        assertEquals(0, backend.openCalls)
        assertTrue(secrets.closed)
        reject("invalidFailure") { VncNativeFailure("raw java.net error: desktop.home.arpa") }
    }

    @Test
    fun backendDiagnosticsAreCollapsedAndSecretsAreZeroized() {
        val available = capabilities()
        val backend = object : VncNativeBackend {
            override fun capabilities() = VncNativeCapabilities.parse(available)
            override fun open(
                request: VncNativeRequest,
                plan: VncNativePlan,
                secrets: VncNativeSecrets,
            ): VncNativeSession = throw IllegalStateException(
                "vnc-secret desktop.home.arpa",
            )
        }
        val password = "vnc-secret".toCharArray()
        val secrets = VncNativeSecrets.take(password)
        reject("connectionFailed") {
            VncNativeAdapter(backend).open(VncNativeRequest.parse(request()), secrets)
        }
        assertTrue(secrets.closed)
        assertTrue(password.all { it == '\u0000' })
    }
}
