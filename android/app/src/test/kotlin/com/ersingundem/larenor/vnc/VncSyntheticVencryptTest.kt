package com.ersingundem.larenor.vnc

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VncSyntheticVencryptTest {
    @Test
    fun exactVencryptX509VncAndPinnedTlsEvidenceReachVncAuth() {
        val negotiation = VncSyntheticVencrypt(PIN)
        assertTrue(negotiation.accept(byteArrayOf(0)).isEmpty())
        val version = negotiation.accept(byteArrayOf(2)).single()
        assertArrayEquals(byteArrayOf(0, 2), version.bytes)
        assertEquals(VncVencryptPhase.STATUS, negotiation.phase)
        assertTrue(negotiation.accept(byteArrayOf(0)).isEmpty())
        val subtype = negotiation.accept(subtypes(257, 261)).single()
        assertArrayEquals(byteArrayOf(0, 0, 1, 5), subtype.bytes)
        assertEquals(VncVencryptPhase.TLS_HANDOFF, negotiation.phase)

        val digest = ByteArray(32)
        negotiation.verifyPeer(
            VncTlsPeerEvidence.take(
                protocol = "TLSv1.3",
                cipherSuite = "TLS_AES_128_GCM_SHA256",
                certificateChainValid = true,
                hostnameVerified = true,
                spkiSha256 = digest,
            ),
        )
        assertTrue(digest.all { it == 0.toByte() })
        assertEquals(VncVencryptPhase.VNC_AUTH_HANDOFF, negotiation.phase)
        negotiation.completeVncAuth(success = true)
        assertEquals(VncVencryptPhase.AUTHENTICATED, negotiation.phase)
        assertFalse(VncRfbEngineAdapter.productionAvailable)
    }

    @Test
    fun versionDowngradeAndNoAuthSubtypeFailClosed() {
        val downgrade = VncSyntheticVencrypt(PIN)
        assertFailure("versionUnavailable") {
            downgrade.accept(byteArrayOf(0, 1))
        }
        assertEquals(VncVencryptPhase.FAILED, downgrade.phase)

        val noAuth = VncSyntheticVencrypt(PIN)
        noAuth.accept(byteArrayOf(0, 2))
        noAuth.accept(byteArrayOf(0))
        assertFailure("subtypeUnavailable") {
            noAuth.accept(subtypes(257, 260))
        }
        assertEquals(0, noAuth.bufferedByteCount)
    }

    @Test
    fun certificateOrPinChangeAndFailedVncAuthAreTerminal() {
        val pinChange = tlsReady()
        val changedDigest = ByteArray(32) { 1 }
        assertFailure("pinMismatch") {
            pinChange.verifyPeer(validEvidence(changedDigest))
        }
        assertTrue(changedDigest.all { it == 0.toByte() })
        assertEquals(VncVencryptPhase.FAILED, pinChange.phase)

        val invalidCertificate = tlsReady()
        assertFailure("tlsEvidenceInvalid") {
            invalidCertificate.verifyPeer(
                VncTlsPeerEvidence.take(
                    protocol = "TLSv1.3",
                    cipherSuite = "TLS_AES_128_GCM_SHA256",
                    certificateChainValid = false,
                    hostnameVerified = true,
                    spkiSha256 = ByteArray(32),
                ),
            )
        }

        val denied = tlsReady()
        denied.verifyPeer(validEvidence(ByteArray(32)))
        assertFailure("authFailed") { denied.completeVncAuth(success = false) }
    }

    @Test
    fun oversizedInputAndCancelWipeStateAndRejectLateSignals() {
        val oversized = VncSyntheticVencrypt(PIN)
        assertFailure("oversizedSecurity") { oversized.accept(ByteArray(1025)) }
        assertEquals(0, oversized.bufferedByteCount)

        val cancelled = VncSyntheticVencrypt(PIN)
        cancelled.accept(byteArrayOf(0))
        assertEquals(1, cancelled.bufferedByteCount)
        cancelled.cancel()
        cancelled.cancel()
        assertEquals(VncVencryptPhase.CANCELLED, cancelled.phase)
        assertEquals(0, cancelled.bufferedByteCount)
        assertFailure("cancelled") { cancelled.accept(byteArrayOf(2)) }
        val lateDigest = ByteArray(32)
        assertFailure("cancelled") {
            cancelled.verifyPeer(validEvidence(lateDigest))
        }
        assertTrue(lateDigest.all { it == 0.toByte() })
    }

    private fun tlsReady(): VncSyntheticVencrypt = VncSyntheticVencrypt(PIN).also {
        it.accept(byteArrayOf(0, 2))
        it.accept(byteArrayOf(0))
        it.accept(subtypes(261))
    }

    private fun validEvidence(digest: ByteArray) = VncTlsPeerEvidence.take(
        protocol = "TLSv1.3",
        cipherSuite = "TLS_AES_128_GCM_SHA256",
        certificateChainValid = true,
        hostnameVerified = true,
        spkiSha256 = digest,
    )

    private fun subtypes(vararg values: Int): ByteArray = buildList {
        add(values.size.toByte())
        for (value in values) {
            add((value ushr 24).toByte())
            add((value ushr 16).toByte())
            add((value ushr 8).toByte())
            add(value.toByte())
        }
    }.toByteArray()

    private fun assertFailure(code: String, action: () -> Unit) {
        val failure = runCatching(action).exceptionOrNull() as VncVencryptFailure
        assertEquals(code, failure.code)
        assertFalse(failure.toString().contains("certificate"))
    }

    companion object {
        private const val PIN =
            "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    }
}
