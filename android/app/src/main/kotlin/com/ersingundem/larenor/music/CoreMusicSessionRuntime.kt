package com.ersingundem.larenor.music

import android.os.SystemClock
import java.util.UUID

interface CoreMusicSessionOwner {
    fun update(snapshot: CoreMusicSessionSnapshot)
    fun shutdown()
}

/** Process-memory-only launch and action authority. Nothing is persisted. */
object CoreMusicSessionRuntime {
    private data class Pending(
        val ticket: String,
        val snapshot: CoreMusicSessionSnapshot,
        val deadline: Long,
    )

    private val gate = CoreMusicSessionActionGate()
    private var pending: Pending? = null
    private var owner: CoreMusicSessionOwner? = null
    private var actionSink: ((CoreMusicSessionAction) -> Unit)? = null

    val hasOwner get() = owner != null
    val snapshot get() = gate.snapshot()

    fun stage(snapshot: CoreMusicSessionSnapshot, foreground: Boolean): String {
        if (!foreground || pending != null || owner != null) {
            throw CoreMusicSessionRejected(if (!foreground) "foregroundRequired" else "busy")
        }
        val ticket = UUID.randomUUID().toString()
        pending = Pending(ticket, snapshot, SystemClock.elapsedRealtime() + 5_000)
        return ticket
    }

    fun consume(ticket: String?, foreground: Boolean): CoreMusicSessionSnapshot? {
        val value = pending ?: return null
        pending = null
        if (!foreground || ticket != value.ticket ||
            SystemClock.elapsedRealtime() >= value.deadline) return null
        gate.publish(value.snapshot)
        return value.snapshot
    }

    fun attach(value: CoreMusicSessionOwner) {
        if (owner != null && owner !== value) throw CoreMusicSessionRejected("busy")
        owner = value
        snapshot?.let(value::update)
    }

    fun update(value: CoreMusicSessionSnapshot) {
        val old = snapshot
        val currentOwner = owner
        if (old == null || old.sessionId != value.sessionId || currentOwner == null) {
            failClosed()
            throw CoreMusicSessionRejected("stale")
        }
        gate.publish(value)
        currentOwner.update(value)
    }

    fun begin(action: String, value: Long?) {
        val current = snapshot ?: throw CoreMusicSessionRejected("unavailable")
        val event = gate.begin(current.sessionId, current.playerRevision, action, value)
        val sink = actionSink
        if (sink == null) {
            failClosed()
            throw CoreMusicSessionRejected("unavailable")
        }
        try { sink(event) } catch (_: Exception) {
            failClosed()
            throw CoreMusicSessionRejected("unavailable")
        }
    }

    fun setActionSink(value: ((CoreMusicSessionAction) -> Unit)?) {
        actionSink = value
        if (value == null && snapshot?.controlsAuthorized == true) failClosed()
    }

    fun clear(expectedSessionId: String? = null) {
        if (expectedSessionId != null && snapshot?.sessionId != expectedSessionId) {
            throw CoreMusicSessionRejected("stale")
        }
        pending = null
        gate.failClosed()
        val previous = owner
        owner = null
        previous?.shutdown()
    }

    fun detach(value: CoreMusicSessionOwner) {
        if (owner === value) owner = null
        gate.failClosed()
        pending = null
    }

    fun failClosed() = clear()
}
