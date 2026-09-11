package com.ersingundem.larenor.vnc

import java.security.MessageDigest
import java.util.Base64

internal enum class VncVencryptPhase {
    VERSION,
    STATUS,
    SUBTYPES,
    TLS_HANDOFF,
    VNC_AUTH_HANDOFF,
    AUTHENTICATED,
    CANCELLED,
    FAILED,
}

internal class VncVencryptFailure(val code: String) :
    RuntimeException("Synthetic VeNCrypt operation rejected") {
    override fun toString() = "VncVencryptFailure($code)"
}

internal class VncVencryptOutbound(bytes: ByteArray) {
    val bytes = bytes.copyOf()
}

/**
 * Minimal evidence emitted by a future audited TLS transport.
 *
 * Certificate objects, subjects, hostnames, and diagnostic strings never cross
 * this boundary. The caller transfers ownership of [spkiSha256].
 */
internal class VncTlsPeerEvidence private constructor(
    val protocol: String,
    val cipherSuite: String,
    val certificateChainValid: Boolean,
    val hostnameVerified: Boolean,
    private var digest: ByteArray?,
) : AutoCloseable {
    internal fun useDigest(block: (ByteArray) -> Unit) {
        block(digest ?: throw VncVencryptFailure("tlsEvidenceInvalid"))
    }

    override fun close() {
        digest?.fill(0)
        digest = null
    }

    override fun toString() = "VncTlsPeerEvidence(<redacted>)"

    companion object {
        fun take(
            protocol: String,
            cipherSuite: String,
            certificateChainValid: Boolean,
            hostnameVerified: Boolean,
            spkiSha256: ByteArray,
        ): VncTlsPeerEvidence {
            if (spkiSha256.size != SHA256_BYTES ||
                !TOKEN.matches(protocol) ||
                !TOKEN.matches(cipherSuite)
            ) {
                spkiSha256.fill(0)
                throw VncVencryptFailure("tlsEvidenceInvalid")
            }
            return VncTlsPeerEvidence(
                protocol,
                cipherSuite,
                certificateChainValid,
                hostnameVerified,
                spkiSha256,
            )
        }

        private const val SHA256_BYTES = 32
        private val TOKEN = Regex("[A-Za-z0-9_.-]{1,64}")
    }
}

/** In-memory VeNCrypt 0.2/X509Vnc characterization with no TLS implementation. */
internal class VncSyntheticVencrypt(expectedSpkiFingerprint: String) {
    var phase = VncVencryptPhase.VERSION
        private set
    var failure: VncVencryptFailure? = null
        private set
    val bufferedByteCount: Int get() = pending.size

    private var pending = ByteArray(0)
    private var expectedDigest = decodeFingerprint(expectedSpkiFingerprint)

    fun accept(bytes: ByteArray): List<VncVencryptOutbound> {
        ensureOpen()
        return try {
            if (bytes.isEmpty()) reject("malformedSecurity")
            if (phase in setOf(
                    VncVencryptPhase.TLS_HANDOFF,
                    VncVencryptPhase.VNC_AUTH_HANDOFF,
                    VncVencryptPhase.AUTHENTICATED,
                )
            ) {
                reject("malformedSecurity")
            }
            append(bytes)
            val outbound = mutableListOf<VncVencryptOutbound>()
            while (true) {
                val progressed = when (phase) {
                    VncVencryptPhase.VERSION -> parseVersion()?.let(outbound::add) != null
                    VncVencryptPhase.STATUS -> parseStatus()
                    VncVencryptPhase.SUBTYPES -> parseSubtypes()?.let(outbound::add) != null
                    else -> false
                }
                if (!progressed) break
            }
            outbound
        } catch (error: VncVencryptFailure) {
            failClosed(error)
        } catch (_: Exception) {
            failClosed(VncVencryptFailure("malformedSecurity"))
        }
    }

    fun verifyPeer(evidence: VncTlsPeerEvidence) {
        try {
            ensureOpen()
            if (phase != VncVencryptPhase.TLS_HANDOFF ||
                evidence.protocol != REQUIRED_TLS_PROTOCOL ||
                evidence.cipherSuite !in ALLOWED_CIPHERS ||
                !evidence.certificateChainValid ||
                !evidence.hostnameVerified
            ) {
                reject("tlsEvidenceInvalid")
            }
            var matches = false
            evidence.useDigest { actual ->
                matches = MessageDigest.isEqual(expectedDigest, actual)
            }
            if (!matches) reject("pinMismatch")
            expectedDigest.fill(0)
            expectedDigest = ByteArray(0)
            phase = VncVencryptPhase.VNC_AUTH_HANDOFF
        } catch (error: VncVencryptFailure) {
            if (phase != VncVencryptPhase.CANCELLED) failClosed(error)
            throw error
        } catch (_: Exception) {
            val error = VncVencryptFailure("tlsEvidenceInvalid")
            failClosed(error)
        } finally {
            evidence.close()
        }
    }

    fun completeVncAuth(success: Boolean) {
        ensureOpen()
        try {
            if (phase != VncVencryptPhase.VNC_AUTH_HANDOFF || !success) {
                reject("authFailed")
            }
            phase = VncVencryptPhase.AUTHENTICATED
        } catch (error: VncVencryptFailure) {
            failClosed(error)
        }
    }

    fun cancel() {
        if (phase == VncVencryptPhase.CANCELLED || phase == VncVencryptPhase.FAILED) return
        wipe()
        phase = VncVencryptPhase.CANCELLED
    }

    private fun parseVersion(): VncVencryptOutbound? {
        if (pending.size < VERSION.size) return null
        if (pending[0] != VERSION[0] || pending[1] != VERSION[1]) {
            reject("versionUnavailable")
        }
        consume(VERSION.size)
        phase = VncVencryptPhase.STATUS
        return VncVencryptOutbound(VERSION)
    }

    private fun parseStatus(): Boolean {
        if (pending.isEmpty()) return false
        if (unsigned(pending[0]) != STATUS_ACCEPTED) reject("versionUnavailable")
        consume(1)
        phase = VncVencryptPhase.SUBTYPES
        return true
    }

    private fun parseSubtypes(): VncVencryptOutbound? {
        if (pending.isEmpty()) return null
        val count = unsigned(pending[0])
        if (count !in 1..MAX_SUBTYPES) reject("subtypeUnavailable")
        val length = 1 + count * SUBTYPE_BYTES
        if (pending.size < length) return null
        var found = false
        repeat(count) { index ->
            if (unsigned32(pending, 1 + index * SUBTYPE_BYTES) == X509_VNC_SUBTYPE) {
                found = true
            }
        }
        if (!found) reject("subtypeUnavailable")
        consume(length)
        if (pending.isNotEmpty()) reject("malformedSecurity")
        phase = VncVencryptPhase.TLS_HANDOFF
        return VncVencryptOutbound(byteArrayOf(0, 0, 1, 5))
    }

    private fun append(bytes: ByteArray) {
        val length = pending.size.toLong() + bytes.size
        if (length > MAX_SECURITY_BYTES) reject("oversizedSecurity")
        val next = ByteArray(length.toInt())
        pending.copyInto(next)
        bytes.copyInto(next, pending.size)
        pending.fill(0)
        pending = next
    }

    private fun consume(length: Int) {
        if (length !in 0..pending.size) reject("malformedSecurity")
        val remaining = pending.copyOfRange(length, pending.size)
        pending.fill(0)
        pending = remaining
    }

    private fun ensureOpen() {
        when (phase) {
            VncVencryptPhase.CANCELLED -> throw VncVencryptFailure("cancelled")
            VncVencryptPhase.FAILED -> throw failure ?: VncVencryptFailure("malformedSecurity")
            else -> Unit
        }
    }

    private fun reject(code: String): Nothing = throw VncVencryptFailure(code)

    private fun failClosed(error: VncVencryptFailure): Nothing {
        wipe()
        failure = error
        phase = VncVencryptPhase.FAILED
        throw error
    }

    private fun wipe() {
        pending.fill(0)
        pending = ByteArray(0)
        expectedDigest.fill(0)
        expectedDigest = ByteArray(0)
    }

    companion object {
        private val VERSION = byteArrayOf(0, 2)
        private const val STATUS_ACCEPTED = 0
        private const val X509_VNC_SUBTYPE = 261L
        private const val SUBTYPE_BYTES = 4
        private const val MAX_SUBTYPES = 16
        private const val MAX_SECURITY_BYTES = 1024L
        private const val REQUIRED_TLS_PROTOCOL = "TLSv1.3"
        private val ALLOWED_CIPHERS = setOf(
            "TLS_AES_128_GCM_SHA256",
            "TLS_AES_256_GCM_SHA384",
            "TLS_CHACHA20_POLY1305_SHA256",
        )

        private fun decodeFingerprint(value: String): ByteArray {
            if (!Regex("SHA256:[A-Za-z0-9+/]{43}").matches(value)) {
                throw VncVencryptFailure("pinMismatch")
            }
            return try {
                Base64.getDecoder().decode(value.removePrefix("SHA256:") + "=").also {
                    if (it.size != 32) {
                        it.fill(0)
                        throw VncVencryptFailure("pinMismatch")
                    }
                }
            } catch (error: VncVencryptFailure) {
                throw error
            } catch (_: Exception) {
                throw VncVencryptFailure("pinMismatch")
            }
        }

        private fun unsigned(value: Byte) = value.toInt() and 0xff

        private fun unsigned32(bytes: ByteArray, offset: Int): Long =
            (unsigned(bytes[offset]).toLong() shl 24) or
                (unsigned(bytes[offset + 1]).toLong() shl 16) or
                (unsigned(bytes[offset + 2]).toLong() shl 8) or
                unsigned(bytes[offset + 3]).toLong()
    }
}
