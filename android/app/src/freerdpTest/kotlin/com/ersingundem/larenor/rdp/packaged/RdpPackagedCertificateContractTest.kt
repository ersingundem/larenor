package com.ersingundem.larenor.rdp.packaged

import java.security.MessageDigest
import java.util.Base64
import okhttp3.tls.HeldCertificate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RdpPackagedCertificateContractTest {
    @Test
    fun exactBoundedPemProducesOnlyTheSpkiPin() {
        val held = HeldCertificate.Builder().commonName("owned-rdp.invalid").build()
        val pem = held.certificatePem().encodeToByteArray()
        val expected = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(
            MessageDigest.getInstance("SHA-256").digest(held.certificate.publicKey.encoded),
        )

        assertEquals(expected, packagedSpkiPinFromX509Pem(pem))
        assertFalse(expected.contains("owned-rdp"))
    }

    @Test
    fun derMalformedMultipleAndOversizedInputsFailClosed() {
        val held = HeldCertificate.Builder().commonName("owned-rdp.invalid").build()
        val pem = held.certificatePem().encodeToByteArray()

        assertNull(packagedSpkiPinFromX509Pem(held.certificate.encoded))
        assertNull(packagedSpkiPinFromX509Pem(byteArrayOf()))
        assertNull(packagedSpkiPinFromX509Pem(pem + byteArrayOf(0)))
        assertNull(packagedSpkiPinFromX509Pem(pem + pem))
        assertNull(packagedSpkiPinFromX509Pem(ByteArray(64 * 1024 + 1) { 'A'.code.toByte() }))
    }

    @Test
    fun certificateCallbackIsBoundToExactDirectPeerKind() {
        assertTrue(packagedDirectPeerCertificate("rdp.invalid", 3390, "rdp.invalid", 3390, 0))
        assertFalse(packagedDirectPeerCertificate("rdp.invalid", 3390, "other.invalid", 3390, 0))
        assertFalse(packagedDirectPeerCertificate("rdp.invalid", 3390, "rdp.invalid", 3391, 0))
        assertFalse(packagedDirectPeerCertificate("rdp.invalid", 3390, "rdp.invalid", 3390, 0x20))
    }
}
