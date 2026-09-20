package com.ersingundem.larenor.rdp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RdpFreeRdpPackageTest {
    @Test
    fun exactReleaseIdentityAndSupportedAbiAreRequiredBeforeLoading() {
        val accepted = RdpFreeRdpPackage.verify(
            identity(
                version = RdpFreeRdpPackage.VERSION,
                sourceCommit = RdpFreeRdpPackage.SOURCE_COMMIT,
                sourceSha256 = RdpFreeRdpPackage.SOURCE_SHA256,
                abi = "arm64-v8a",
            ),
        )
        assertTrue(accepted)

        val mismatches = listOf(
            identity(version = "3.31.0"),
            identity(sourceCommit = "0".repeat(40)),
            identity(sourceSha256 = "0".repeat(64)),
            identity(abi = "armeabi-v7a"),
            identity(jniSchema = 2),
            identity(enabledChannels = setOf("cliprdr", "rdpsnd")),
        )
        mismatches.forEach { assertFalse(RdpFreeRdpPackage.verify(it)) }
    }

    @Test
    fun unavailableOrMismatchedPackageNeverCreatesANativeOperation() {
        val runtime = Runtime(identity(version = "unreviewed"))
        val backend = RdpFreeRdpBackend(runtime)
        assertFalse(backend.capabilities().canConnect)

        val adapter = RdpNativeAdapter(backend)
        val secrets = RdpNativeSecrets.take("secret".toCharArray(), null)
        val failure = runCatching {
            adapter.open(RdpNativeRequest.parse(request()), secrets)
        }.exceptionOrNull() as RdpNativeFailure
        assertEquals("engineUnavailable", failure.code)
        assertEquals(0, runtime.createCalls)
        assertTrue(secrets.closed)
    }

    private fun identity(
        version: String = RdpFreeRdpPackage.VERSION,
        sourceCommit: String = RdpFreeRdpPackage.SOURCE_COMMIT,
        sourceSha256: String = RdpFreeRdpPackage.SOURCE_SHA256,
        abi: String = "x86_64",
        jniSchema: Int = 1,
        enabledChannels: Set<String> = emptySet(),
    ) = RdpFreeRdpIdentity(
        version = version,
        sourceCommit = sourceCommit,
        sourceSha256 = sourceSha256,
        abi = abi,
        jniSchema = jniSchema,
        enabledChannels = enabledChannels,
    )

    private class Runtime(private val value: RdpFreeRdpIdentity) : RdpJniRuntime {
        var createCalls = 0
        override fun identity() = value
        override fun capabilities() = capabilitiesFixture()
        override fun create(
            request: RdpNativeRequest,
            plan: RdpNativeNegotiated,
            listener: RdpJniOperation.Listener,
        ): RdpJniOperation {
            createCalls++
            error("must not create")
        }
    }

    companion object {
        private fun capabilitiesFixture() = mapOf<String, Any?>(
            "schemaVersion" to 1,
            "availability" to "available",
            "engineRevision" to RdpFreeRdpPackage.ENGINE_REVISION,
            "security" to mapOf("tls" to true, "certificatePinning" to true, "nla" to true, "rdGateway" to false),
            "display" to mapOf("dynamicResolution" to true, "externalDisplay" to true, "maxWidth" to 4096, "maxHeight" to 2160, "maxDpi" to 480),
            "input" to mapOf("pointer" to true, "keyboard" to true, "ime" to true),
            "channels" to mapOf("clipboardModes" to listOf("disabled"), "audio" to false, "files" to false),
        )

        private fun request() = mapOf<String, Any?>(
            "schemaVersion" to 1,
            "requestId" to "11111111-1111-4111-8111-111111111111",
            "targetHost" to "fixture.invalid",
            "targetPort" to 3389,
            "username" to "fixture",
            "domain" to "TEST",
            "gateway" to null,
            "certificateFingerprint" to "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "requiresNla" to true,
            "display" to mapOf("width" to 1280, "height" to 800, "dpi" to 180, "externalDisplay" to false, "dynamicResize" to true),
            "keyboardLayout" to "automatic",
            "clipboardMode" to "disabled",
            "audio" to false,
            "files" to false,
        )
    }
}
