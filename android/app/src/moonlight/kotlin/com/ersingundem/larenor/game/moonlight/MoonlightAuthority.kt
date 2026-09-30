package com.ersingundem.larenor.game.moonlight

import java.security.MessageDigest

private val IDENTITY = Regex("^[0-9a-f]{32}$")
private val DIGEST = Regex("^[0-9a-f]{64}$")
internal const val MAX_JS_REVISION = 9_007_199_254_740_991L

internal fun requireIdentity(value: String, name: String): String =
    value.takeIf(IDENTITY::matches) ?: throw MoonlightRuntimeFailure("invalid_$name")

internal fun requireRevision(value: Long, name: String): Long =
    value.takeIf { it in 0..MAX_JS_REVISION } ?: throw MoonlightRuntimeFailure("invalid_$name")

internal fun sha256(value: ByteArray): ByteArray =
    MessageDigest.getInstance("SHA-256").digest(value)

internal fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

internal fun publicRevision(vararg values: String): Long {
    val hex = sha256(values.joinToString("\u0000").toByteArray(Charsets.UTF_8)).hex()
    return hex.take(13).toLong(16) + 1L
}

class MoonlightRuntimeFailure(val code: String) : RuntimeException(code) {
    init {
        require(code in setOf(
            "authority_changed", "busy", "cancelled", "engine_unavailable",
            "foreground_required", "invalid_account_id", "invalid_authority_id",
            "invalid_candidate", "invalid_candidate_revision", "invalid_core_id",
            "invalid_family_id", "invalid_home_id", "invalid_pairing_revision",
            "invalid_request_id", "invalid_revision", "invalid_session_id",
            "invalid_timeout", "invalid_receipt", "provider_unavailable",
            "pin_required", "quarantined", "stale_candidate", "stale_pairing", "unknown_effect",
        ))
    }

    override fun toString(): String = "MoonlightRuntimeFailure($code)"
}

data class MoonlightScope(
    val coreId: String,
    val homeId: String,
    val accountId: String,
    val familyId: String,
) {
    init {
        requireIdentity(coreId, "core_id")
        requireIdentity(homeId, "home_id")
        requireIdentity(accountId, "account_id")
        requireIdentity(familyId, "family_id")
    }

    internal val storageKey: String = sha256(
        listOf(coreId, homeId, accountId, familyId).joinToString("\u0000").toByteArray(Charsets.UTF_8),
    ).hex()

    override fun toString(): String = "MoonlightScope(<redacted>)"
}

data class MoonlightAuthority(
    val authorityId: String,
    val epoch: Long,
    val scope: MoonlightScope,
    val clientInstanceId: String,
    val accountRevision: Long,
    val pinRevision: Long,
    val pinConfigured: Boolean,
    val pinUnlocked: Boolean,
    val routeRevision: Long,
    val lifecycleRevision: Long,
    val idleRevision: Long,
    val interactionRevision: Long,
) {
    init {
        requireIdentity(authorityId, "authority_id")
        requireIdentity(clientInstanceId, "candidate")
        requireRevision(epoch, "revision")
        requireRevision(accountRevision, "revision")
        requireRevision(pinRevision, "revision")
        requireRevision(routeRevision, "revision")
        requireRevision(lifecycleRevision, "revision")
        requireRevision(idleRevision, "revision")
        requireRevision(interactionRevision, "revision")
    }

    internal val fingerprint: String = sha256(
        listOf(
            authorityId, epoch, scope.storageKey, clientInstanceId, accountRevision, pinRevision,
            pinConfigured, pinUnlocked,
            routeRevision, lifecycleRevision, idleRevision, interactionRevision,
        ).joinToString("\u0000").toByteArray(Charsets.UTF_8),
    ).hex()

    override fun toString(): String = "MoonlightAuthority(<redacted>)"
}

internal fun MoonlightAuthority.sameSafetyOwner(other: MoonlightAuthority): Boolean =
    scope == other.scope && accountRevision == other.accountRevision

data class MoonlightCandidate(
    val candidateId: String,
    val candidateRevision: Long,
    val displayName: String,
    val powerState: String,
    val pairState: String,
    val hostIdentityDigest: String,
) {
    init {
        requireIdentity(candidateId, "candidate")
        requireRevision(candidateRevision, "candidate_revision")
        require(displayName.isNotBlank() && displayName.length <= 128)
        require(powerState in setOf("awake", "asleep", "unknown"))
        require(pairState in setOf("paired", "notPaired", "unknown"))
        require(DIGEST.matches(hostIdentityDigest))
    }
}

data class MoonlightPairedHost(
    val hostHandle: String,
    val credentialHandle: String,
    val displayName: String,
    val pairingRevision: Long,
    val serverFingerprint: String,
    val codecs: Set<String>,
) {
    init {
        requireIdentity(hostHandle, "candidate")
        requireIdentity(credentialHandle, "candidate")
        require(displayName.isNotBlank() && displayName.length <= 128)
        requireRevision(pairingRevision, "pairing_revision")
        require(DIGEST.matches(serverFingerprint))
        require(codecs.isNotEmpty() && codecs.all { it in setOf("h264", "hevc", "av1") })
    }
}

data class MoonlightPairReceipt(
    val requestId: String,
    val status: String,
    val readbackRevision: Long,
    val host: MoonlightPairedHost? = null,
    val nativeObservationJson: String? = null,
    val nativeReceiptDigest: String = sha256(
        "$requestId\u0000$status\u0000$readbackRevision\u0000${nativeObservationJson.orEmpty()}".toByteArray(),
    ).hex(),
) {
    init {
        requireIdentity(requestId, "request_id")
        require(status in setOf("paired", "rejected", "unknown"))
        requireRevision(readbackRevision, "revision")
        require((status == "paired") == (host != null))
        require((status == "paired") == (nativeObservationJson != null))
        require(Regex("^[0-9a-f]{64}$").matches(nativeReceiptDigest))
    }
}

data class MoonlightPairAuthorization(
    val requestId: String,
    val pairingId: String,
    val expectedPairingRevision: Long,
    val pairingGrant: String,
    val expiresAtEpochSeconds: Double,
) {
    init {
        requireIdentity(requestId, "request_id")
        requireIdentity(pairingId, "candidate")
        requireRevision(expectedPairingRevision, "pairing_revision")
        requireIdentity(pairingGrant, "candidate")
        require(expiresAtEpochSeconds.isFinite() && expiresAtEpochSeconds > 0)
    }

    internal val grantDigest: String = sha256(pairingGrant.toByteArray(Charsets.UTF_8)).hex()
    override fun toString(): String = "MoonlightPairAuthorization(<redacted>)"
}

data class MoonlightApp(
    val appHandle: String,
    val title: String,
    val appRevision: Long,
    val hdrSupported: Boolean,
    val running: Boolean,
) {
    init {
        requireIdentity(appHandle, "candidate")
        require(title.isNotBlank() && title.length <= 256)
        requireRevision(appRevision, "revision")
    }
}

data class MoonlightRevokeReceipt(
    val requestId: String,
    val status: String,
    val readbackRevision: Long?,
) {
    init {
        requireIdentity(requestId, "request_id")
        require(status in setOf("revoked", "unknown"))
        if (readbackRevision != null) requireRevision(readbackRevision, "revision")
        require((status == "revoked") == (readbackRevision != null))
    }
}

data class MoonlightCatalogAuthorization(
    val requestId: String,
    val catalogObservationId: String,
    val expectedObservationRevision: Long,
    val expectedCatalogRevision: Long,
    val catalogGrant: String,
    val expiresAtEpochSeconds: Double,
) {
    init {
        requireIdentity(requestId, "request_id")
        requireIdentity(catalogObservationId, "candidate")
        requireRevision(expectedObservationRevision, "revision")
        requireRevision(expectedCatalogRevision, "revision")
        requireIdentity(catalogGrant, "candidate")
        require(expiresAtEpochSeconds.isFinite() && expiresAtEpochSeconds > 0)
    }

    internal val grantDigest = sha256(catalogGrant.toByteArray(Charsets.UTF_8)).hex()
    override fun toString(): String = "MoonlightCatalogAuthorization(<redacted>)"
}

data class MoonlightCatalogReceipt(
    val requestId: String,
    val catalogObservationId: String,
    val state: String,
    val readbackRevision: Long,
    val nativeObservationJson: String? = null,
    val nativeReceiptDigest: String = sha256(
        "$requestId\u0000$catalogObservationId\u0000$state\u0000$readbackRevision\u0000${nativeObservationJson.orEmpty()}".toByteArray(),
    ).hex(),
) {
    init {
        requireIdentity(requestId, "request_id")
        requireIdentity(catalogObservationId, "candidate")
        require(state in setOf("observed", "unknown"))
        requireRevision(readbackRevision, "revision")
        require((state == "observed") == (nativeObservationJson != null))
        require(Regex("^[0-9a-f]{64}$").matches(nativeReceiptDigest))
    }
}

data class MoonlightSelectedQuality(
    val codec: String,
    val codecId: String,
    val codecRevision: Long,
    val displayId: Int,
    val displayRevision: Long,
    val networkId: String,
    val networkRevision: Long,
    val policyId: String,
    val policyRevision: Long,
    val widthPixels: Int,
    val heightPixels: Int,
    val framesPerSecond: Int,
    val bitrateKbps: Int,
    val frameQueueDepth: Int,
    val inputQueueDepth: Int,
    val secureSurface: Boolean,
) {
    init {
        require(codec in setOf("h264", "hevc", "av1"))
        requireIdentity(codecId, "candidate")
        requireRevision(codecRevision, "revision")
        require(displayId in 0..63)
        requireRevision(displayRevision, "revision")
        requireIdentity(networkId, "candidate")
        requireRevision(networkRevision, "revision")
        requireIdentity(policyId, "candidate")
        requireRevision(policyRevision, "revision")
        require(widthPixels in 320..8192 && heightPixels in 320..8192)
        require(framesPerSecond in 24..240 && bitrateKbps in 2_000..100_000)
        require(frameQueueDepth in 1..3 && inputQueueDepth in 1..32)
        require(secureSurface)
    }

    internal val fingerprint: String = sha256(listOf(
        codec, codecId, codecRevision.toString(), displayId.toString(), displayRevision.toString(),
        networkId, networkRevision.toString(), policyId, policyRevision.toString(),
        widthPixels.toString(), heightPixels.toString(), framesPerSecond.toString(),
        bitrateKbps.toString(), frameQueueDepth.toString(), inputQueueDepth.toString(),
        secureSurface.toString(),
    ).joinToString("\u0000").toByteArray(Charsets.UTF_8)).hex()
}

data class MoonlightBoundSession(
    val sessionId: String,
    val sessionRevision: Long,
    val hostId: String,
    val hostRevision: Long,
    val pairingRevision: Long,
    val catalogRevision: Long,
    val appId: String,
    val appRevision: Long,
    val expiresAtEpochSeconds: Double,
    val selectedQuality: MoonlightSelectedQuality,
) {
    init {
        requireIdentity(sessionId, "session_id")
        requireRevision(sessionRevision, "revision")
        requireIdentity(hostId, "candidate")
        requireRevision(hostRevision, "revision")
        requireRevision(pairingRevision, "pairing_revision")
        requireRevision(catalogRevision, "revision")
        requireIdentity(appId, "candidate")
        requireRevision(appRevision, "revision")
        require(expiresAtEpochSeconds.isFinite() && expiresAtEpochSeconds > 0)
    }
}

data class MoonlightCommandReceipt(
    val requestId: String,
    val sessionId: String,
    val commandId: String,
    val state: String,
    val result: String,
    val observationKind: String,
    val readbackRevision: Long?,
    val nativeReceiptDigest: String?,
) {
    init {
        requireIdentity(requestId, "request_id")
        requireIdentity(sessionId, "session_id")
        requireIdentity(commandId, "candidate")
        require(state in setOf("native_observed", "rejected", "unknown"))
        require(result in setOf("hostAwake", "appRunning", "streaming", "stopped", "rejected", "unknown"))
        require(observationKind in setOf(
            "serverInfoOnline", "currentGameMatched", "connectionStarted", "connectionTerminated",
            "connectionStopped",
            "nativeRejected", "unknown",
        ))
        require((state == "unknown") == (result == "unknown"))
        if (readbackRevision != null) requireRevision(readbackRevision, "revision")
        require(nativeReceiptDigest == null || Regex("^[0-9a-f]{64}$").matches(nativeReceiptDigest))
        require(when (state) {
            "unknown" -> readbackRevision == null && nativeReceiptDigest == null
            "native_observed", "rejected" -> readbackRevision != null && nativeReceiptDigest != null
            else -> false
        })
    }
}
