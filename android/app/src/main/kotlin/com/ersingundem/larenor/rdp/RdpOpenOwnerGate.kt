package com.ersingundem.larenor.rdp

/** Object-identity lease; invalidation cannot wrap or become current again after focus returns. */
internal class RdpOpenOwnerGate {
    internal class Lease internal constructor(
        internal val generation: Any,
        internal val sink: Any,
    )

    private var generation: Any = Any()

    @Synchronized
    fun capture(sink: Any): Lease = Lease(generation, sink)

    @Synchronized
    fun isCurrent(lease: Lease, sink: Any?): Boolean =
        generation === lease.generation && sink === lease.sink

    /**
     * Commits publication while holding the same monitor used by invalidation.
     * A caller may perform an earlier advisory [isCurrent] check, but must only
     * expose shared state from [publish].
     */
    @Synchronized
    fun publishIfCurrent(lease: Lease, sink: Any?, publish: () -> Unit): Boolean {
        if (generation !== lease.generation || sink !== lease.sink) return false
        publish()
        return true
    }

    /** Invalidates only the exact owner; a replacement owner is never fenced. */
    @Synchronized
    fun invalidateIfCurrent(lease: Lease, sink: Any?, invalidatePublication: () -> Unit): Boolean {
        if (generation !== lease.generation || sink !== lease.sink) return false
        generation = Any()
        invalidatePublication()
        return true
    }

    /** Invalidates the owner and mutates its shared publication atomically. */
    @Synchronized
    fun <T> invalidate(invalidatePublication: () -> T): T {
        generation = Any()
        return invalidatePublication()
    }

    fun invalidate() = invalidate { Unit }
}
