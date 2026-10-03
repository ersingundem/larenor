package com.ersingundem.larenor.game.moonlight

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.security.SecureRandom

private const val MAX_OUTPUT_WITNESS_COUNT = 1

enum class MoonlightLeaseState {
    FLUTTER_OWNED,
    TRANSFER_PENDING,
    GAME_VISIBLE,
    RETIRING,
    RETIRED,
    UNCERTAIN,
}

data class MoonlightLaunchSpec(
    val authority: MoonlightAuthority,
    val sessionId: String,
    val epoch: Long,
    val commandFingerprint: String,
    internal val host: String,
    internal val port: Int,
    internal val httpsPort: Int,
    internal val appName: String,
    internal val appId: Int,
    internal val uniqueId: String,
    internal val computerUuid: String,
    internal val computerName: String,
    internal val supportsHdr: Boolean,
    internal val serverCertificate: ByteArray,
    internal val displayId: Int,
    internal val maximumLifetimeMillis: Long,
    internal val maximumIdleMillis: Long,
) {
    init {
        requireIdentity(sessionId, "session_id")
        requireRevision(epoch, "revision")
        require(Regex("^[0-9a-f]{64}$").matches(commandFingerprint))
        require(host.isNotBlank() && host.length <= 255)
        require(port in 1..65535)
        // Pinned Moonlight persists addresses and the server certificate, but
        // deliberately treats the HTTPS port as transient. Game and NvHTTP use
        // zero as "discover from serverinfo"; the HTTPS connection still uses
        // the stored server-certificate pin.
        require(httpsPort in 0..65535)
        require(appName.isNotBlank() && appName.length <= 256)
        require(appId >= 0)
        require(Regex("^[0-9A-Fa-f]{16}$").matches(uniqueId))
        require(computerUuid.isNotBlank() && computerUuid.length <= 128)
        require(computerName.isNotBlank() && computerName.length <= 128)
        require(serverCertificate.size in 256..16_384)
        require(displayId in 0..63)
        require(maximumLifetimeMillis in 1..3_600_000)
        require(maximumIdleMillis in 1..3_600_000)
    }

    override fun toString(): String = "MoonlightLaunchSpec(<redacted>)"
}

data class MoonlightLeaseSnapshot(
    val token: String,
    val sessionId: String,
    val epoch: Long,
    val state: MoonlightLeaseState,
    val readbackRevision: Long,
) {
    override fun toString(): String = "MoonlightLeaseSnapshot(<redacted>)"
}

data class MoonlightLeaseObservation(
    val snapshot: MoonlightLeaseSnapshot,
    val observationKind: String,
    val result: String,
)

data class MoonlightOutputWitnessSnapshot(
    val sessionId: String,
    val epoch: Long,
    val renderedFrameCount: Int,
    val acceptedAudioWriteCount: Int,
) {
    init {
        requireIdentity(sessionId, "session_id")
        requireRevision(epoch, "revision")
        require(renderedFrameCount in 0..MAX_OUTPUT_WITNESS_COUNT)
        require(acceptedAudioWriteCount in 0..MAX_OUTPUT_WITNESS_COUNT)
    }

    override fun toString(): String = "MoonlightOutputWitnessSnapshot(<redacted>)"
}

data class MoonlightConnectionBoundarySnapshot(
    val sessionId: String,
    val epoch: Long,
    val surfaceCreated: Boolean,
    val positiveSurfaceChanged: Boolean,
    val stageStarted: Boolean,
    val stageCompleted: Boolean,
    val stageFailed: Boolean,
    val connectionStarted: Boolean,
) {
    init {
        requireIdentity(sessionId, "session_id")
        requireRevision(epoch, "revision")
    }

    override fun toString(): String = "MoonlightConnectionBoundarySnapshot(<redacted>)"
}

internal data class MoonlightTerminalWitnessSnapshot(
    val sessionId: String,
    val epoch: Long,
    val state: MoonlightLeaseState,
    val observationKind: String,
    val readbackRevision: Long,
) {
    init {
        requireIdentity(sessionId, "session_id")
        requireRevision(epoch, "revision")
        require(state in setOf(MoonlightLeaseState.RETIRED, MoonlightLeaseState.UNCERTAIN))
        require(observationKind in setOf("connectionTerminated", "connectionStopped", "unknown"))
        requireRevision(readbackRevision, "revision")
    }

    override fun toString(): String = "MoonlightTerminalWitnessSnapshot(<redacted>)"
}

/** Process-private ownership transfer between the Flutter and embedded Game activities. */
object MoonlightForegroundLeaseRegistry {
    private data class Entry(
        val token: String,
        val spec: MoonlightLaunchSpec,
        var state: MoonlightLeaseState,
        var readbackRevision: Long,
        var activity: Activity? = null,
        val observers: MutableList<(MoonlightLeaseObservation) -> Unit> = mutableListOf(),
        var started: Boolean = false,
        var localStopStarted: Boolean = false,
        var lastInputAtMillis: Long = SystemClock.elapsedRealtime(),
        var idleRunnable: Runnable? = null,
        var renderedFrameCount: Int = 0,
        var acceptedAudioWriteCount: Int = 0,
        var terminalObservationKind: String? = null,
        var surfaceCreatedObserved: Boolean = false,
        var positiveSurfaceChangedObserved: Boolean = false,
        var stageStartedObserved: Boolean = false,
        var stageCompletedObserved: Boolean = false,
        var stageFailedObserved: Boolean = false,
        var connectionStartedObserved: Boolean = false,
    )

    private val random = SecureRandom()
    private val main = Handler(Looper.getMainLooper())
    private var current: Entry? = null

    @Synchronized
    fun issue(
        spec: MoonlightLaunchSpec,
        observer: ((MoonlightLeaseObservation) -> Unit)? = null,
    ): MoonlightLeaseSnapshot {
        val existing = current
        if (existing != null && existing.state !in setOf(MoonlightLeaseState.RETIRED)) {
            throw MoonlightRuntimeFailure(if (existing.state == MoonlightLeaseState.UNCERTAIN) "quarantined" else "busy")
        }
        val token = ByteArray(16).also(random::nextBytes).hex()
        val entry = Entry(token, spec, MoonlightLeaseState.TRANSFER_PENDING, 1)
        if (observer != null) entry.observers += observer
        current = entry
        main.postDelayed({ expireTransfer(token) }, TRANSFER_TIMEOUT_MS)
        main.postDelayed({ expireLifetime(token) }, spec.maximumLifetimeMillis)
        return entry.snapshot()
    }

    @Synchronized
    fun resolveForLaunch(token: String): MoonlightLaunchSpec {
        requireIdentity(token, "candidate")
        val entry = current
        if (entry?.token != token || entry.state != MoonlightLeaseState.TRANSFER_PENDING) {
            throw MoonlightRuntimeFailure("foreground_required")
        }
        return entry.spec
    }

    @Synchronized
    fun claim(token: String, activity: Activity): MoonlightLeaseSnapshot {
        val entry = exact(token)
        if (entry.state != MoonlightLeaseState.TRANSFER_PENDING || entry.activity != null) {
            throw MoonlightRuntimeFailure("foreground_required")
        }
        entry.activity = activity
        entry.state = MoonlightLeaseState.GAME_VISIBLE
        entry.readbackRevision += 1
        entry.lastInputAtMillis = SystemClock.elapsedRealtime()
        scheduleIdle(entry, entry.spec.maximumIdleMillis)
        return entry.snapshot()
    }

    @Synchronized
    fun connectionStarted(token: String): MoonlightLeaseSnapshot? {
        val entry = current?.takeIf { it.token == token } ?: return null
        if (entry.state in ACTIVE_BOUNDARY_STATES) {
            entry.connectionStartedObserved = true
        }
        if (entry.state != MoonlightLeaseState.GAME_VISIBLE || entry.activity == null) {
            throw MoonlightRuntimeFailure("foreground_required")
        }
        if (entry.started) return entry.snapshot()
        entry.started = true
        entry.readbackRevision += 1
        notify(entry, "connectionStarted", "streaming")
        return entry.snapshot()
    }

    @Synchronized
    fun surfaceCreated(token: String): MoonlightConnectionBoundarySnapshot? =
        observeBoundary(token) { it.surfaceCreatedObserved = true }

    @Synchronized
    fun positiveSurfaceChanged(
        token: String,
        width: Int,
        height: Int,
    ): MoonlightConnectionBoundarySnapshot? {
        requireIdentity(token, "candidate")
        if (width <= 0 || height <= 0) return null
        return observeBoundary(token) { it.positiveSurfaceChangedObserved = true }
    }

    @Synchronized
    fun stageStarted(token: String): MoonlightConnectionBoundarySnapshot? =
        observeBoundary(token) { it.stageStartedObserved = true }

    @Synchronized
    fun stageCompleted(token: String): MoonlightConnectionBoundarySnapshot? =
        observeBoundary(token) { it.stageCompletedObserved = true }

    @Synchronized
    fun stageFailed(token: String): MoonlightConnectionBoundarySnapshot? =
        observeBoundary(token) { it.stageFailedObserved = true }

    @Synchronized
    internal fun connectionBoundarySnapshot(token: String): MoonlightConnectionBoundarySnapshot? {
        requireIdentity(token, "candidate")
        val entry = current?.takeIf { it.token == token } ?: return null
        if (entry.state !in ACTIVE_BOUNDARY_STATES) return null
        return entry.connectionBoundarySnapshot()
    }

    @Synchronized
    internal fun terminalConnectionBoundarySnapshot(token: String): MoonlightConnectionBoundarySnapshot? {
        requireIdentity(token, "candidate")
        val entry = current?.takeIf { it.token == token } ?: return null
        if (entry.state !in TERMINAL_BOUNDARY_STATES) return null
        return entry.connectionBoundarySnapshot()
    }

    @Synchronized
    fun videoFrameRendered(token: String): MoonlightOutputWitnessSnapshot? {
        val entry = activeOutputEntry(token) ?: return null
        if (entry.renderedFrameCount < MAX_OUTPUT_WITNESS_COUNT) {
            entry.renderedFrameCount += 1
        }
        return entry.outputSnapshot()
    }

    @Synchronized
    fun audioPcmWritten(
        token: String,
        requestedSamples: Int,
        writtenSamples: Int,
    ): MoonlightOutputWitnessSnapshot? {
        if (requestedSamples <= 0 || writtenSamples != requestedSamples) return null
        val entry = activeOutputEntry(token) ?: return null
        if (entry.acceptedAudioWriteCount < MAX_OUTPUT_WITNESS_COUNT) {
            entry.acceptedAudioWriteCount += 1
        }
        return entry.outputSnapshot()
    }

    @Synchronized
    fun outputWitnessSnapshot(token: String): MoonlightOutputWitnessSnapshot =
        exact(token).outputSnapshot()

    @Synchronized
    internal fun terminalWitnessSnapshot(token: String): MoonlightTerminalWitnessSnapshot? =
        exact(token).terminalSnapshot()

    @Synchronized
    fun gameHidden(token: String, pictureInPicture: Boolean): MoonlightLeaseSnapshot? {
        val entry = current?.takeIf { it.token == token } ?: return null
        if (entry.state == MoonlightLeaseState.GAME_VISIBLE && !pictureInPicture) {
            entry.state = MoonlightLeaseState.RETIRING
            entry.readbackRevision += 1
            beginRetirement(entry)
        }
        return entry.snapshot()
    }

    @Synchronized
    fun connectionTerminated(token: String): MoonlightLeaseSnapshot? {
        val entry = current?.takeIf { it.token == token } ?: return null
        entry.idleRunnable?.let(main::removeCallbacks)
        entry.idleRunnable = null
        entry.state = MoonlightLeaseState.RETIRED
        entry.activity = null
        entry.readbackRevision += 1
        entry.terminalObservationKind = "connectionTerminated"
        notify(entry, "connectionTerminated", "stopped")
        return entry.snapshot()
    }

    @Synchronized
    fun connectionStopStarted(token: String): MoonlightLeaseSnapshot? {
        val entry = current?.takeIf { it.token == token } ?: return null
        if (entry.state != MoonlightLeaseState.RETIRING) return null
        entry.localStopStarted = true
        return entry.snapshot()
    }

    @Synchronized
    fun connectionStopped(token: String): MoonlightLeaseSnapshot? {
        val entry = current?.takeIf { it.token == token } ?: return null
        if (entry.state != MoonlightLeaseState.RETIRING || !entry.localStopStarted) return null
        entry.idleRunnable?.let(main::removeCallbacks)
        entry.idleRunnable = null
        entry.state = MoonlightLeaseState.RETIRED
        entry.activity = null
        entry.readbackRevision += 1
        entry.terminalObservationKind = "connectionStopped"
        notify(entry, "connectionStopped", "stopped")
        return entry.snapshot()
    }

    @Synchronized
    fun gameDestroyed(token: String): MoonlightLeaseSnapshot? {
        val entry = current?.takeIf { it.token == token } ?: return null
        entry.idleRunnable?.let(main::removeCallbacks)
        entry.idleRunnable = null
        if (entry.state == MoonlightLeaseState.RETIRING && entry.localStopStarted) {
            // The actual NvConnection.stop worker owns terminal readback. Keep
            // the lease fenced while Activity destruction races that worker.
            entry.activity = null
        } else if (entry.state != MoonlightLeaseState.RETIRED) {
            entry.state = MoonlightLeaseState.UNCERTAIN
            entry.activity = null
            entry.readbackRevision += 1
            entry.terminalObservationKind = "unknown"
            notify(entry, "unknown", "unknown")
        }
        return entry.snapshot()
    }

    @Synchronized
    fun retire(authorityId: String, epoch: Long): MoonlightLeaseSnapshot? {
        requireIdentity(authorityId, "authority_id")
        requireRevision(epoch, "revision")
        val entry = current ?: return null
        if (entry.spec.authority.authorityId != authorityId || entry.spec.authority.epoch != epoch) return null
        if (entry.state !in setOf(MoonlightLeaseState.RETIRED, MoonlightLeaseState.UNCERTAIN)) {
            entry.state = MoonlightLeaseState.RETIRING
            entry.readbackRevision += 1
            beginRetirement(entry)
        }
        return entry.snapshot()
    }

    @Synchronized
    fun retireSession(sessionId: String, epoch: Long): MoonlightLeaseSnapshot? {
        requireIdentity(sessionId, "session_id")
        requireRevision(epoch, "revision")
        val entry = current ?: return null
        if (entry.spec.sessionId != sessionId || entry.spec.epoch != epoch) return null
        if (entry.state !in setOf(MoonlightLeaseState.RETIRED, MoonlightLeaseState.UNCERTAIN)) {
            entry.state = MoonlightLeaseState.RETIRING
            entry.readbackRevision += 1
            beginRetirement(entry)
        }
        return entry.snapshot()
    }

    @Synchronized
    fun snapshot(token: String): MoonlightLeaseSnapshot = exact(token).snapshot()

    @Synchronized
    fun observe(token: String, observer: (MoonlightLeaseObservation) -> Unit) {
        val entry = exact(token)
        entry.observers += observer
    }

    @Synchronized
    fun ownsHostCover(authorityId: String, epoch: Long): Boolean {
        val entry = current ?: return false
        return entry.spec.authority.authorityId == authorityId && entry.spec.authority.epoch == epoch &&
            entry.state in setOf(MoonlightLeaseState.TRANSFER_PENDING, MoonlightLeaseState.GAME_VISIBLE)
    }

    @Synchronized
    fun ownedSnapshot(
        authorityId: String,
        authorityEpoch: Long,
        sessionId: String,
        sessionEpoch: Long,
    ): MoonlightLeaseSnapshot? {
        val entry = current ?: return null
        if (entry.spec.authority.authorityId != authorityId || entry.spec.authority.epoch != authorityEpoch ||
            entry.spec.sessionId != sessionId || entry.spec.epoch != sessionEpoch ||
            entry.state !in setOf(MoonlightLeaseState.TRANSFER_PENDING, MoonlightLeaseState.GAME_VISIBLE)
        ) return null
        return entry.snapshot()
    }

    @Synchronized
    fun safetyStopSnapshot(
        authorityId: String,
        authorityEpoch: Long,
        sessionId: String,
        sessionEpoch: Long,
    ): MoonlightLeaseSnapshot? {
        val entry = current ?: return null
        if (entry.spec.authority.authorityId != authorityId || entry.spec.authority.epoch != authorityEpoch ||
            entry.spec.sessionId != sessionId || entry.spec.epoch != sessionEpoch ||
            entry.state !in setOf(
                MoonlightLeaseState.TRANSFER_PENDING,
                MoonlightLeaseState.GAME_VISIBLE,
                MoonlightLeaseState.RETIRING,
            )
        ) return null
        return entry.snapshot()
    }

    @Synchronized
    fun inputActivity(token: String): MoonlightLeaseSnapshot? {
        val entry = current?.takeIf { it.token == token } ?: return null
        if (entry.state != MoonlightLeaseState.GAME_VISIBLE || entry.activity == null) return null
        entry.lastInputAtMillis = SystemClock.elapsedRealtime()
        scheduleIdle(entry, entry.spec.maximumIdleMillis)
        return entry.snapshot()
    }

    @Synchronized
    internal fun pendingIdleTimerCountForTest(): Int = if (current?.idleRunnable != null) 1 else 0

    @Synchronized
    internal fun clearForTest() {
        current?.idleRunnable?.let(main::removeCallbacks)
        current = null
    }

    @Synchronized
    private fun expireTransfer(token: String) {
        val entry = current ?: return
        if (entry.token == token && entry.state == MoonlightLeaseState.TRANSFER_PENDING) {
            entry.state = MoonlightLeaseState.UNCERTAIN
            entry.readbackRevision += 1
            entry.terminalObservationKind = "unknown"
            notify(entry, "unknown", "unknown")
        }
    }

    @Synchronized
    private fun expireLifetime(token: String) {
        val entry = current?.takeIf { it.token == token } ?: return
        if (entry.state in setOf(MoonlightLeaseState.RETIRED, MoonlightLeaseState.UNCERTAIN)) return
        entry.state = MoonlightLeaseState.RETIRING
        entry.readbackRevision += 1
        beginRetirement(entry)
    }

    @Synchronized
    private fun expireIdle(token: String) {
        val entry = current?.takeIf { it.token == token } ?: return
        entry.idleRunnable = null
        if (entry.state != MoonlightLeaseState.GAME_VISIBLE) return
        val remaining = entry.spec.maximumIdleMillis - (SystemClock.elapsedRealtime() - entry.lastInputAtMillis)
        if (remaining > 0) {
            scheduleIdle(entry, remaining)
            return
        }
        entry.state = MoonlightLeaseState.RETIRING
        entry.readbackRevision += 1
        beginRetirement(entry)
    }

    @Synchronized
    private fun expireRetirement(token: String) {
        val entry = current?.takeIf { it.token == token } ?: return
        if (entry.state != MoonlightLeaseState.RETIRING) return
        entry.state = MoonlightLeaseState.UNCERTAIN
        entry.activity = null
        entry.readbackRevision += 1
        entry.terminalObservationKind = "unknown"
        notify(entry, "unknown", "unknown")
    }

    private fun beginRetirement(entry: Entry) {
        entry.idleRunnable?.let(main::removeCallbacks)
        entry.idleRunnable = null
        finish(entry)
        if (entry.state == MoonlightLeaseState.RETIRING) {
            main.postDelayed({ expireRetirement(entry.token) }, TERMINATION_TIMEOUT_MS)
        }
    }

    private fun finish(entry: Entry) {
        val activity = entry.activity
        val ownedTaskFlags = android.content.Intent.FLAG_ACTIVITY_NEW_DOCUMENT or
            android.content.Intent.FLAG_ACTIVITY_MULTIPLE_TASK
        if (activity == null || activity.intent.flags and ownedTaskFlags != ownedTaskFlags) {
            entry.state = MoonlightLeaseState.UNCERTAIN
            entry.readbackRevision += 1
            notify(entry, "unknown", "unknown")
            return
        }
        main.post { activity.finishAndRemoveTask() }
    }

    private fun notify(entry: Entry, observationKind: String, result: String) {
        if (entry.observers.isEmpty()) return
        val observation = MoonlightLeaseObservation(entry.snapshot(), observationKind, result)
        val observers = entry.observers.toList()
        main.post { observers.forEach { it(observation) } }
    }

    private fun scheduleIdle(entry: Entry, delayMillis: Long) {
        entry.idleRunnable?.let(main::removeCallbacks)
        val task = Runnable { expireIdle(entry.token) }
        entry.idleRunnable = task
        main.postDelayed(task, delayMillis)
    }

    private fun exact(token: String): Entry {
        requireIdentity(token, "candidate")
        return current?.takeIf { it.token == token } ?: throw MoonlightRuntimeFailure("foreground_required")
    }

    private fun activeOutputEntry(token: String): Entry? {
        requireIdentity(token, "candidate")
        return current?.takeIf {
            it.token == token &&
                it.state == MoonlightLeaseState.GAME_VISIBLE &&
                it.activity != null &&
                it.started &&
                !it.localStopStarted
        }
    }

    private fun observeBoundary(
        token: String,
        update: (Entry) -> Unit,
    ): MoonlightConnectionBoundarySnapshot? {
        requireIdentity(token, "candidate")
        val entry = current?.takeIf {
            it.token == token && it.state in ACTIVE_BOUNDARY_STATES
        } ?: return null
        update(entry)
        return entry.connectionBoundarySnapshot()
    }

    private fun Entry.snapshot() = MoonlightLeaseSnapshot(
        token = token,
        sessionId = spec.sessionId,
        epoch = spec.epoch,
        state = state,
        readbackRevision = readbackRevision,
    )

    private fun Entry.outputSnapshot() = MoonlightOutputWitnessSnapshot(
        sessionId = spec.sessionId,
        epoch = spec.epoch,
        renderedFrameCount = renderedFrameCount,
        acceptedAudioWriteCount = acceptedAudioWriteCount,
    )

    private fun Entry.connectionBoundarySnapshot() = MoonlightConnectionBoundarySnapshot(
        sessionId = spec.sessionId,
        epoch = spec.epoch,
        surfaceCreated = surfaceCreatedObserved,
        positiveSurfaceChanged = positiveSurfaceChangedObserved,
        stageStarted = stageStartedObserved,
        stageCompleted = stageCompletedObserved,
        stageFailed = stageFailedObserved,
        connectionStarted = connectionStartedObserved,
    )

    private fun Entry.terminalSnapshot(): MoonlightTerminalWitnessSnapshot? {
        val observationKind = terminalObservationKind ?: return null
        return MoonlightTerminalWitnessSnapshot(
            sessionId = spec.sessionId,
            epoch = spec.epoch,
            state = state,
            observationKind = observationKind,
            readbackRevision = readbackRevision,
        )
    }

    private const val TRANSFER_TIMEOUT_MS = 5_000L
    private const val TERMINATION_TIMEOUT_MS = 5_000L
    private val ACTIVE_BOUNDARY_STATES = setOf(
        MoonlightLeaseState.TRANSFER_PENDING,
        MoonlightLeaseState.GAME_VISIBLE,
    )
    private val TERMINAL_BOUNDARY_STATES = setOf(
        MoonlightLeaseState.RETIRED,
        MoonlightLeaseState.UNCERTAIN,
    )
}
