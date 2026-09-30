package com.ersingundem.larenor.rdp

/** Keeps native graphics paused until the consumer has released its old frame. */
internal class RdpFrameDeliveryGate {
    enum class Resume { REJECTED, IDLE, FRAME_REQUIRED }

    private var nextSequence = 1L
    private var pendingSequence: Long? = null
    private var acknowledged = false
    private var dirty = false
    private var closed = false

    @Synchronized
    fun offer(): Long? {
        if (closed) return null
        if (pendingSequence != null) {
            dirty = true
            return null
        }
        return nextSequence++.also { pendingSequence = it }
    }

    @Synchronized
    fun acknowledge(sequence: Long): Boolean {
        if (closed || pendingSequence != sequence || acknowledged) return false
        // ACK must not admit a new callback while the consumer still owns and
        // zeroizes the previous buffer. Only resume releases that boundary.
        acknowledged = true
        return true
    }

    @Synchronized
    fun resume(): Resume {
        if (closed || pendingSequence == null || !acknowledged) return Resume.REJECTED
        pendingSequence = null
        acknowledged = false
        val result = if (dirty) Resume.FRAME_REQUIRED else Resume.IDLE
        dirty = false
        return result
    }

    @Synchronized
    fun close() {
        closed = true
        pendingSequence = null
        acknowledged = false
        dirty = false
    }
}
