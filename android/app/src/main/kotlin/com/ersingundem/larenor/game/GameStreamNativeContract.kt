package com.ersingundem.larenor.game

private val IDENTITY = Regex("^[0-9a-f]{32}$")
private const val MAX_REVISION = Long.MAX_VALUE - 1

internal fun gameStreamFail(code: String): Nothing = throw GameStreamNativeFailure(code)

class GameStreamNativeFailure(val code: String) : RuntimeException(code) {
    init {
        if (code !in setOf(
                "invalidRequest", "invalidCredentialHandle", "staleSession",
                "foregroundRequired", "engineUnavailable", "unsupported",
                "busy", "cancelled", "idempotencyConflict", "invalidReceipt",
                "unknownEffect",
            )
        ) throw IllegalArgumentException("invalidFailure")
    }

    fun publicDetails(): Map<String, Any> = mapOf(
        "code" to code,
        "retryable" to false,
    )

    override fun toString() = "GameStreamNativeFailure($code)"
}

class GameStreamCredentialHandle private constructor(private val value: String) {
    internal fun forEngine(): String = value

    override fun toString() = "GameStreamCredentialHandle(<redacted>)"

    companion object {
        fun parse(raw: Any?): GameStreamCredentialHandle {
            val value = raw as? String ?: gameStreamFail("invalidCredentialHandle")
            if (!IDENTITY.matches(value)) gameStreamFail("invalidCredentialHandle")
            return GameStreamCredentialHandle(value)
        }
    }
}

data class GameStreamNativeBinding(
    val sessionId: String,
    val epoch: Long,
    val accountRevision: Long,
    val routeRevision: Long,
    val lifecycleRevision: Long,
    val idleRevision: Long,
    val interactionRevision: Long,
    val credentialHandle: GameStreamCredentialHandle,
) {
    override fun toString() = "GameStreamNativeBinding(<redacted>)"

    companion object {
        private val keys = setOf(
            "sessionId", "epoch", "accountRevision", "routeRevision",
            "lifecycleRevision", "idleRevision", "interactionRevision",
            "credentialHandle",
        )

        fun parse(raw: Any?): GameStreamNativeBinding {
            val value = strictMap(raw, keys)
            return GameStreamNativeBinding(
                sessionId = gameStreamIdentity(value["sessionId"]),
                epoch = gameStreamRevision(value["epoch"]),
                accountRevision = gameStreamRevision(value["accountRevision"]),
                routeRevision = gameStreamRevision(value["routeRevision"]),
                lifecycleRevision = gameStreamRevision(value["lifecycleRevision"]),
                idleRevision = gameStreamRevision(value["idleRevision"]),
                interactionRevision = gameStreamRevision(value["interactionRevision"]),
                credentialHandle = GameStreamCredentialHandle.parse(value["credentialHandle"]),
            )
        }
    }
}

enum class GameStreamNativeIntent(val wire: String) {
    WAKE("wake"), LAUNCH("launch"), STREAM("stream"), STOP("stop");

    companion object {
        fun parse(raw: Any?): GameStreamNativeIntent = entries.firstOrNull { it.wire == raw }
            ?: gameStreamFail("invalidRequest")
    }
}

data class GameStreamNativeRevisions(
    val hostRevision: Long,
    val pairingRevision: Long,
    val appRevision: Long,
    val displayRevision: Long,
    val codecRevision: Long,
    val networkRevision: Long,
    val policyRevision: Long,
) {
    fun toChannel(): Map<String, Long> = mapOf(
        "hostRevision" to hostRevision,
        "pairingRevision" to pairingRevision,
        "appRevision" to appRevision,
        "displayRevision" to displayRevision,
        "codecRevision" to codecRevision,
        "networkRevision" to networkRevision,
        "policyRevision" to policyRevision,
    )

    companion object {
        private val keys = setOf(
            "hostRevision", "pairingRevision", "appRevision", "displayRevision",
            "codecRevision", "networkRevision", "policyRevision",
        )

        fun parse(raw: Any?): GameStreamNativeRevisions {
            val value = strictMap(raw, keys)
            return GameStreamNativeRevisions(
                hostRevision = gameStreamRevision(value["hostRevision"]),
                pairingRevision = gameStreamRevision(value["pairingRevision"]),
                appRevision = gameStreamRevision(value["appRevision"]),
                displayRevision = gameStreamRevision(value["displayRevision"]),
                codecRevision = gameStreamRevision(value["codecRevision"]),
                networkRevision = gameStreamRevision(value["networkRevision"]),
                policyRevision = gameStreamRevision(value["policyRevision"]),
            )
        }
    }
}

data class GameStreamNativeCommand(
    val sessionId: String,
    val commandId: String,
    val requestId: String,
    val intent: GameStreamNativeIntent,
    val hostId: String,
    val appId: String,
    val displayId: Int,
    val codecId: String,
    val networkId: String,
    val policyId: String,
    val revisions: GameStreamNativeRevisions,
) {
    override fun toString() = "GameStreamNativeCommand(${intent.wire}, <redacted>)"

    companion object {
        private val keys = setOf(
            "sessionId", "commandId", "requestId", "intent", "hostId", "appId",
            "displayId", "codecId", "networkId", "policyId", "revisions",
        )

        fun parse(raw: Any?): GameStreamNativeCommand {
            val value = strictMap(raw, keys)
            val display = integer(value["displayId"])
            if (display !in 0..63) gameStreamFail("invalidRequest")
            return GameStreamNativeCommand(
                sessionId = gameStreamIdentity(value["sessionId"]),
                commandId = gameStreamIdentity(value["commandId"]),
                requestId = gameStreamIdentity(value["requestId"]),
                intent = GameStreamNativeIntent.parse(value["intent"]),
                hostId = gameStreamIdentity(value["hostId"]),
                appId = gameStreamIdentity(value["appId"]),
                displayId = display,
                codecId = gameStreamIdentity(value["codecId"]),
                networkId = gameStreamIdentity(value["networkId"]),
                policyId = gameStreamIdentity(value["policyId"]),
                revisions = GameStreamNativeRevisions.parse(value["revisions"]),
            )
        }
    }
}

data class GameStreamEngineReceipt(
    val sessionId: String,
    val commandId: String,
    val requestId: String,
    val intent: GameStreamNativeIntent,
    val revisions: GameStreamNativeRevisions,
    val accepted: Boolean,
    val observedState: String,
    val readbackRevision: Long,
) {
    fun validatedFor(command: GameStreamNativeCommand): GameStreamEngineReceipt {
        if (sessionId != command.sessionId || commandId != command.commandId ||
            requestId != command.requestId || intent != command.intent ||
            revisions != command.revisions || readbackRevision !in 1..MAX_REVISION ||
            observedState !in setOf("hostAwake", "appRunning", "streaming", "stopped", "rejected")
        ) gameStreamFail("invalidReceipt")
        return this
    }

    fun toChannel(): Map<String, Any> = mapOf(
        "sessionId" to sessionId,
        "commandId" to commandId,
        "requestId" to requestId,
        "intent" to intent.wire,
        "revisions" to revisions.toChannel(),
        "accepted" to accepted,
        "observedState" to observedState,
        "readbackRevision" to readbackRevision,
    )
}

data class GameStreamNativeCapabilities(
    val availability: String,
    val engineRevision: String?,
    val intents: Set<GameStreamNativeIntent>,
) {
    init {
        val revisionSafe = engineRevision?.matches(Regex("^[A-Za-z0-9._-]{1,128}$")) == true
        if ((availability == "available" && (!revisionSafe || intents.isEmpty())) ||
            (availability == "unavailable" && (engineRevision != null || intents.isNotEmpty())) ||
            availability !in setOf("available", "unavailable") ||
            intents.size > GameStreamNativeIntent.entries.size
        ) gameStreamFail("invalidRequest")
    }

    fun toChannel(): Map<String, Any?> = mapOf(
        "schemaVersion" to 1,
        "availability" to availability,
        "engineRevision" to engineRevision,
        "intents" to intents.map { it.wire }.sorted(),
        "maxInflight" to 1,
    )

    companion object {
        fun unavailable() = GameStreamNativeCapabilities("unavailable", null, emptySet())
    }
}

interface GameStreamNativeEngine {
    fun capabilities(): GameStreamNativeCapabilities
    fun execute(
        command: GameStreamNativeCommand,
        credentialHandle: String,
        callback: (GameStreamEngineReceipt?, GameStreamNativeFailure?) -> Unit,
    )
    fun retire(sessionId: String)
}

internal fun strictMap(raw: Any?, keys: Set<String>): Map<*, *> {
    val value = raw as? Map<*, *> ?: gameStreamFail("invalidRequest")
    if (value.keys.any { it !is String } || value.keys.toSet() != keys) gameStreamFail("invalidRequest")
    return value
}

internal fun gameStreamIdentity(raw: Any?): String {
    val value = raw as? String ?: gameStreamFail("invalidRequest")
    if (!IDENTITY.matches(value)) gameStreamFail("invalidRequest")
    return value
}

private fun integer(raw: Any?): Int {
    val asLong = wholeNumber(raw)
    if (asLong !in Int.MIN_VALUE..Int.MAX_VALUE) {
        gameStreamFail("invalidRequest")
    }
    return asLong.toInt()
}

internal fun gameStreamRevision(raw: Any?): Long {
    val asLong = wholeNumber(raw)
    if (asLong !in 1..MAX_REVISION) gameStreamFail("invalidRequest")
    return asLong
}

private fun wholeNumber(raw: Any?): Long = when (raw) {
    is Byte -> raw.toLong()
    is Short -> raw.toLong()
    is Int -> raw.toLong()
    is Long -> raw
    else -> gameStreamFail("invalidRequest")
}
