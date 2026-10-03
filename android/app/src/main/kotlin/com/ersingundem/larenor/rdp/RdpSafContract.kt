package com.ersingundem.larenor.rdp

import java.nio.charset.StandardCharsets
import java.security.MessageDigest

internal class RdpSafFailure(val code: String) : RuntimeException() {
    init {
        require(code in CODES)
    }

    override fun toString(): String = "RdpSafFailure($code)"

    companion object {
        val CODES = setOf(
            "busy",
            "cancelled",
            "permission_denied",
            "authority_changed",
            "unavailable",
            "invalid_request",
        )
    }
}

internal data class RdpSafAuthority private constructor(
    val namespaceDigest: String,
    val profileRef: String,
    val profileRevision: Long,
    val authorityId: String,
) {
    override fun toString(): String = "RdpSafAuthority(<redacted>)"

    companion object {
        fun create(namespaceDigest: String, profileRef: String, profileRevision: Long): RdpSafAuthority {
            val canonical = buildString {
                append(RdpSafContract.AUTHORITY_DOMAIN)
                append('\u0000')
                append(namespaceDigest)
                append('\u0000')
                append(profileRef)
                append('\u0000')
                append(profileRevision)
            }.toByteArray(StandardCharsets.UTF_8)
            val digest = MessageDigest.getInstance("SHA-256").digest(canonical)
            canonical.fill(0)
            return RdpSafAuthority(
                namespaceDigest,
                profileRef,
                profileRevision,
                digest.joinToString("") { "%02x".format(it) },
            )
        }
    }
}

internal data class RdpSafSelectRequest(
    val requestId: String,
    val authority: RdpSafAuthority,
)

internal data class RdpSafGrantRequest(
    val requestId: String,
    val authority: RdpSafAuthority,
    val grantId: String,
    val expectedGrantRevision: Long,
)

internal enum class RdpSafPublicState(val wire: String) {
    PREPARED("prepared"),
    ACTIVE("active"),
    RETIRED("retired"),
    UNKNOWN("unknown"),
}

internal object RdpSafContract {
    const val SCHEMA_VERSION = 5
    const val AUTHORITY_DOMAIN = "larenor-rdp-saf-authority-v1"
    const val MAX_JS_SAFE_INTEGER = 9_007_199_254_740_991L
    val UUID = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    val HEX_32 = Regex("^[0-9a-f]{32}$")
    val HEX_64 = Regex("^[0-9a-f]{64}$")

    fun select(raw: Any?): RdpSafSelectRequest {
        val value = exactMap(raw, setOf("schemaVersion", "requestId", "authority"))
        schema(value)
        return RdpSafSelectRequest(requestId(value), authority(value["authority"]))
    }

    fun cancel(raw: Any?): String {
        val value = exactMap(raw, setOf("schemaVersion", "requestId"))
        schema(value)
        return requestId(value)
    }

    fun grant(raw: Any?): RdpSafGrantRequest {
        val value = exactMap(
            raw,
            setOf("schemaVersion", "requestId", "authority", "grantId", "expectedGrantRevision"),
        )
        schema(value)
        val grantId = value["grantId"] as? String ?: invalid()
        if (!HEX_32.matches(grantId)) invalid()
        return RdpSafGrantRequest(
            requestId(value),
            authority(value["authority"]),
            grantId,
            exactPositiveLong(value["expectedGrantRevision"]),
        )
    }

    fun authority(raw: Any?): RdpSafAuthority {
        val value = exactMap(
            raw,
            setOf("schemaVersion", "namespaceDigest", "profileRef", "profileRevision"),
        )
        schema(value)
        val namespaceDigest = value["namespaceDigest"] as? String ?: invalid()
        val profileRef = value["profileRef"] as? String ?: invalid()
        if (!HEX_64.matches(namespaceDigest) || !HEX_64.matches(profileRef)) invalid()
        return RdpSafAuthority.create(
            namespaceDigest,
            profileRef,
            exactPositiveLong(value["profileRevision"]),
        )
    }

    fun receipt(
        requestId: String,
        authorityId: String,
        grantId: String,
        grantRevision: Long,
        state: RdpSafPublicState,
    ): Map<String, Any> {
        if (!UUID.matches(requestId) || !HEX_64.matches(authorityId) || !HEX_32.matches(grantId) ||
            grantRevision !in 1..MAX_JS_SAFE_INTEGER
        ) invalid()
        return mapOf(
            "schemaVersion" to SCHEMA_VERSION,
            "requestId" to requestId,
            "authorityId" to authorityId,
            "grantId" to grantId,
            "grantRevision" to grantRevision,
            "state" to state.wire,
        )
    }

    private fun requestId(value: Map<*, *>): String {
        val requestId = value["requestId"] as? String ?: invalid()
        if (!UUID.matches(requestId)) invalid()
        return requestId
    }

    private fun schema(value: Map<*, *>) {
        if (value["schemaVersion"] != SCHEMA_VERSION) invalid()
    }

    private fun exactPositiveLong(raw: Any?): Long {
        val value = when (raw) {
            is Int -> raw.toLong()
            is Long -> raw
            else -> invalid()
        }
        if (value !in 1..MAX_JS_SAFE_INTEGER) invalid()
        return value
    }

    private fun exactMap(raw: Any?, keys: Set<String>): Map<*, *> {
        val value = raw as? Map<*, *> ?: invalid()
        if (value.keys != keys) invalid()
        return value
    }

    private fun invalid(): Nothing = throw RdpSafFailure("invalid_request")
}
