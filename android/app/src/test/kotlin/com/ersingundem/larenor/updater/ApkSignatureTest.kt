package com.ersingundem.larenor.updater

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class ApkSignatureTest {
    @Test fun realAospApkSignatureVerifiesAndPayloadTamperingFails() {
        val bytes = javaClass.getResourceAsStream("/updater/aosp-signed-apk.fixture")!!.use { it.readBytes() }
        val file = File.createTempFile("apk-signature", ".apk")
        try {
            file.writeBytes(bytes)
            val certificates = verifiedApkCertificates(file, 35)
            assertEquals(1, certificates.size)
            assertTrue(certificates.single().matches(Regex("[a-f0-9]{64}")))
            // Mutate the first local-file payload, outside APK signing blocks.
            val nameLength = (bytes[26].toInt() and 255) or ((bytes[27].toInt() and 255) shl 8)
            val extraLength = (bytes[28].toInt() and 255) or ((bytes[29].toInt() and 255) shl 8)
            val payload = 30 + nameLength + extraLength
            bytes[payload] = (bytes[payload].toInt() xor 1).toByte()
            file.writeBytes(bytes)
            failure("verification") { verifiedApkCertificates(file, 35) }
        } finally { file.delete() }
    }
    @Test fun arbitraryBytesAreNotAcceptedAsAnApk() {
        val file = File.createTempFile("apk-signature", ".apk")
        try { file.writeText("synthetic non-apk"); failure("verification") { verifiedApkCertificates(file, 35) } }
        finally { file.delete() }
    }
}
