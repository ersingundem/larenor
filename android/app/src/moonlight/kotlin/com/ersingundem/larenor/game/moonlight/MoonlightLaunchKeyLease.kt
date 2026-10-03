package com.ersingundem.larenor.game.moonlight

import android.os.Handler
import android.os.Looper
import android.os.SystemClock

private const val REMOTE_INPUT_KEY_BYTES = 16
private const val MAX_LAUNCH_KEY_TTL_MILLIS = 60_000L
private val DIGEST = Regex("^[0-9a-f]{64}$")

/** Exact process-private ownership for a Sunshine remote-input key. */
internal data class MoonlightLaunchKeyOwner(
    val authorityFingerprint: String,
    val bindingId: String,
    val bindingRevision: Long,
    val sessionId: String,
    val sessionRevision: Long,
    val hostId: String,
    val hostRevision: Long,
    val pairingRevision: Long,
    val catalogRevision: Long,
    val appId: String,
    val appRevision: Long,
    val selectedQualityFingerprint: String,
    val upstreamHostUuid: String,
    val providerHost: String,
    val providerPort: Int,
    val providerHttpsPort: Int,
    val upstreamAppId: Int,
    val uniqueId: String,
    val certificateFingerprint: String,
) {
    init {
        require(DIGEST.matches(authorityFingerprint))
        requireIdentity(bindingId, "candidate")
        requireRevision(bindingRevision, "revision")
        requireIdentity(sessionId, "session_id")
        requireRevision(sessionRevision, "revision")
        requireIdentity(hostId, "candidate")
        requireRevision(hostRevision, "revision")
        requireRevision(pairingRevision, "pairing_revision")
        requireRevision(catalogRevision, "revision")
        requireIdentity(appId, "candidate")
        requireRevision(appRevision, "revision")
        require(DIGEST.matches(selectedQualityFingerprint))
        require(upstreamHostUuid.isNotBlank() && upstreamHostUuid.length <= 128)
        require(providerHost.isNotBlank() && providerHost.length <= 255)
        require(providerPort in 1..65_535)
        require(providerHttpsPort in 0..65_535)
        require(upstreamAppId >= 0)
        require(Regex("^[0-9A-Fa-f]{16}$").matches(uniqueId))
        require(DIGEST.matches(certificateFingerprint))
    }

    override fun toString(): String = "MoonlightLaunchKeyOwner(<redacted>)"
}

/** One consumed key. The caller array is wiped after [use] returns or throws. */
internal class MoonlightLaunchKeyMaterial(
    private var key: ByteArray,
    val keyId: Int,
) : AutoCloseable {
    init {
        require(key.size == REMOTE_INPUT_KEY_BYTES)
        require(keyId >= 0)
    }

    fun <T> use(block: (ByteArray, Int) -> T): T {
        val owned = synchronized(this) {
            val transferred = key.takeIf { it.size == REMOTE_INPUT_KEY_BYTES }
                ?: throw MoonlightRuntimeFailure("authority_changed")
            key = ByteArray(0)
            transferred
        }
        return try {
            block(owned, keyId)
        } finally {
            owned.fill(0)
        }
    }

    override fun close() {
        synchronized(this) {
            key.fill(0)
            key = ByteArray(0)
        }
    }

    override fun toString(): String = "MoonlightLaunchKeyMaterial(<redacted>)"
}

internal data class MoonlightProviderLaunchPlan(
    val verb: String,
    val quitExistingApp: Boolean,
)

internal fun providerLaunchPlan(
    currentAppId: Int,
    selectedAppId: Int,
): MoonlightProviderLaunchPlan {
    require(currentAppId >= 0)
    require(selectedAppId >= 0)
    return when {
        currentAppId == selectedAppId && currentAppId != 0 ->
            MoonlightProviderLaunchPlan("resume", quitExistingApp = false)
        currentAppId == 0 -> MoonlightProviderLaunchPlan("launch", quitExistingApp = false)
        else -> MoonlightProviderLaunchPlan("launch", quitExistingApp = true)
    }
}

internal class MoonlightLaunchKeyReservation internal constructor(
    internal val generation: Long,
    internal val owner: MoonlightLaunchKeyOwner,
) {
    override fun toString(): String = "MoonlightLaunchKeyReservation(<redacted>)"
}

/** A single bounded launch-to-Game handoff. It has no disk, Intent, or DTO form. */
internal class MoonlightLaunchKeyLeaseStore(
    private val nowElapsedMillis: () -> Long,
    private val schedule: (Long, () -> Unit) -> Unit,
) {
    private data class Entry(
        val generation: Long,
        val owner: MoonlightLaunchKeyOwner,
        var key: ByteArray?,
        var keyId: Int?,
        val expiresAtElapsedMillis: Long,
        var token: String? = null,
    )

    private var generation = 0L
    private var activeBinding: Pair<String, Long>? = null
    private var entry: Entry? = null

    fun activateBinding(bindingId: String, bindingRevision: Long) = synchronized(this) {
        requireIdentity(bindingId, "candidate")
        requireRevision(bindingRevision, "revision")
        val next = bindingId to bindingRevision
        if (activeBinding != next) {
            retireLocked()
            generation += 1
            activeBinding = next
        }
    }

    fun reserve(
        owner: MoonlightLaunchKeyOwner,
        ttlMillis: Long,
    ): MoonlightLaunchKeyReservation {
        require(ttlMillis in 1..MAX_LAUNCH_KEY_TTL_MILLIS)
        val nextGeneration: Long
        synchronized(this) {
            if (activeBinding != (owner.bindingId to owner.bindingRevision)) {
                throw MoonlightRuntimeFailure("authority_changed")
            }
            retireLocked()
            nextGeneration = ++generation
            entry = Entry(
                generation = nextGeneration,
                owner = owner,
                key = null,
                keyId = null,
                expiresAtElapsedMillis = nowElapsedMillis() + ttlMillis,
            )
        }
        try {
            schedule(ttlMillis) { expire(nextGeneration) }
        } catch (failure: Throwable) {
            synchronized(this) {
                if (entry?.generation == nextGeneration) retireLocked()
            }
            throw failure
        }
        return MoonlightLaunchKeyReservation(nextGeneration, owner)
    }

    fun publish(
        reservation: MoonlightLaunchKeyReservation,
        key: ByteArray,
        keyId: Int,
    ) = synchronized(this) {
        require(key.size == REMOTE_INPUT_KEY_BYTES)
        require(keyId >= 0)
        val owned = currentLocked()
        if (activeBinding != (reservation.owner.bindingId to reservation.owner.bindingRevision) ||
            owned.generation != reservation.generation || owned.owner != reservation.owner ||
            owned.key != null || owned.keyId != null || owned.token != null
        ) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
        owned.key = key.copyOf()
        owned.keyId = keyId
    }

    /** Issues and binds the foreground token while expiry is excluded by this store lock. */
    fun <T> bindIssued(
        owner: MoonlightLaunchKeyOwner,
        issue: () -> Pair<T, String>,
    ): T = synchronized(this) {
        val owned = exactPendingLocked(owner)
        try {
            val (result, token) = issue()
            requireIdentity(token, "candidate")
            owned.token = token
            result
        } catch (failure: Throwable) {
            if (entry?.generation == owned.generation) retireLocked()
            throw failure
        }
    }

    fun consume(token: String): MoonlightLaunchKeyMaterial = synchronized(this) {
        requireIdentity(token, "candidate")
        val owned = currentLocked()
        if (owned.key?.size != REMOTE_INPUT_KEY_BYTES || owned.keyId == null) {
            throw MoonlightRuntimeFailure("unknown_effect")
        }
        if (owned.token != token) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
        entry = null
        val key = checkNotNull(owned.key)
        val keyId = checkNotNull(owned.keyId)
        owned.key = null
        owned.keyId = null
        MoonlightLaunchKeyMaterial(key, keyId)
    }

    fun retireOwner(owner: MoonlightLaunchKeyOwner) = synchronized(this) {
        if (entry?.owner == owner) retireLocked()
    }

    fun retireReservation(reservation: MoonlightLaunchKeyReservation) = synchronized(this) {
        if (entry?.let {
                it.generation == reservation.generation && it.owner == reservation.owner
            } == true
        ) retireLocked()
    }

    fun retireAuthority(authorityFingerprint: String) = synchronized(this) {
        if (entry?.owner?.authorityFingerprint == authorityFingerprint) retireLocked()
    }

    fun retireBinding(bindingId: String, bindingRevision: Long) = synchronized(this) {
        val binding = bindingId to bindingRevision
        if (activeBinding == binding) {
            retireLocked()
            generation += 1
            activeBinding = null
        }
    }

    fun retireSession(
        bindingId: String,
        bindingRevision: Long,
        sessionId: String,
        sessionRevision: Long,
    ) = synchronized(this) {
        if (entry?.owner?.let {
                it.bindingId == bindingId && it.bindingRevision == bindingRevision &&
                    it.sessionId == sessionId && it.sessionRevision == sessionRevision
            } == true
        ) retireLocked()
    }

    fun retireToken(token: String) = synchronized(this) {
        if (entry?.token == token) retireLocked()
    }

    fun retireAll() = synchronized(this) { retireLocked() }

    private fun exactPendingLocked(owner: MoonlightLaunchKeyOwner): Entry {
        val owned = currentLocked()
        if (activeBinding != (owner.bindingId to owner.bindingRevision) ||
            owned.owner != owner || owned.key?.size != REMOTE_INPUT_KEY_BYTES ||
            owned.keyId == null || owned.token != null
        ) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
        return owned
    }

    private fun currentLocked(): Entry {
        val owned = entry ?: throw MoonlightRuntimeFailure("unknown_effect")
        if (nowElapsedMillis() >= owned.expiresAtElapsedMillis) {
            retireLocked()
            throw MoonlightRuntimeFailure("unknown_effect")
        }
        return owned
    }

    private fun expire(expectedGeneration: Long): Unit = synchronized(this) {
        val owned = entry?.takeIf { it.generation == expectedGeneration } ?: return
        val remaining = owned.expiresAtElapsedMillis - nowElapsedMillis()
        if (remaining > 0) {
            try {
                schedule(remaining) { expire(expectedGeneration) }
            } catch (failure: Throwable) {
                if (entry?.generation == expectedGeneration) retireLocked()
                throw failure
            }
        } else {
            retireLocked()
        }
    }

    private fun retireLocked() {
        entry?.key?.fill(0)
        entry = null
    }
}

internal object MoonlightLaunchKeyLeaseRegistry {
    private val main = Handler(Looper.getMainLooper())
    private val store = MoonlightLaunchKeyLeaseStore(
        nowElapsedMillis = SystemClock::elapsedRealtime,
        schedule = { delay, block ->
            if (!main.postDelayed(block, delay)) throw IllegalStateException("main looper unavailable")
        },
    )

    fun activateBinding(bindingId: String, bindingRevision: Long) =
        store.activateBinding(bindingId, bindingRevision)

    fun reserve(
        owner: MoonlightLaunchKeyOwner,
        ttlMillis: Long,
    ): MoonlightLaunchKeyReservation = store.reserve(owner, ttlMillis)

    fun publish(
        reservation: MoonlightLaunchKeyReservation,
        key: ByteArray,
        keyId: Int,
    ) = store.publish(reservation, key, keyId)

    fun <T> bindIssued(
        owner: MoonlightLaunchKeyOwner,
        issue: () -> Pair<T, String>,
    ): T = store.bindIssued(owner, issue)

    fun consume(token: String): MoonlightLaunchKeyMaterial = store.consume(token)
    fun retireOwner(owner: MoonlightLaunchKeyOwner) = store.retireOwner(owner)
    fun retireReservation(reservation: MoonlightLaunchKeyReservation) =
        store.retireReservation(reservation)
    fun retireAuthority(authorityFingerprint: String) = store.retireAuthority(authorityFingerprint)
    fun retireBinding(bindingId: String, bindingRevision: Long) =
        store.retireBinding(bindingId, bindingRevision)
    fun retireSession(
        bindingId: String,
        bindingRevision: Long,
        sessionId: String,
        sessionRevision: Long,
    ) = store.retireSession(bindingId, bindingRevision, sessionId, sessionRevision)
    fun retireToken(token: String) = store.retireToken(token)
    fun retireAll() = store.retireAll()
}
