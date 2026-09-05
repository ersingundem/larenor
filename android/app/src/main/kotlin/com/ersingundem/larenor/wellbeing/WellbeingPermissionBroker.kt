package com.ersingundem.larenor.wellbeing

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred

/** One-use, short-lived launch ticket. Only this opaque ID enters an Intent. */
class WellbeingPermissionBroker(private val now: () -> Long) {
    class Pending(val token: String, val owner: Any, val metrics: Set<WellbeingMetric>,
        val created: Long, val ownerCurrent: () -> Boolean) {
        var consumed = false
        val finished = CompletableDeferred<Unit>()
    }
    private var pending: Pending? = null
    fun begin(owner: Any, metrics: Set<WellbeingMetric>, foreground: Boolean,
        ownerCurrent: () -> Boolean): Pending {
        require(foreground && ownerCurrent() && metrics.size in 1..3)
        check(pending == null)
        return Pending(UUID.randomUUID().toString(), owner, metrics, now(), ownerCurrent).also { pending = it }
    }
    fun take(token: String?): Pending? {
        val current = pending ?: return null
        if (token != current.token || current.consumed || !current.ownerCurrent() ||
            now() - current.created !in 0..5000) return null
        current.consumed = true
        return current
    }
    fun active(token: String?): Pending? = pending?.takeIf {
        it.token == token && it.consumed && it.ownerCurrent()
    }
    fun finish(token: String?) {
        val current = pending ?: return
        if (current.token != token) return
        pending = null
        current.finished.complete(Unit)
    }
    fun disposeOwner(owner: Any) {
        pending?.takeIf { it.owner === owner }?.let { finish(it.token) }
    }
}

object WellbeingPermissionRuntime {
    val broker = WellbeingPermissionBroker { android.os.SystemClock.uptimeMillis() }
}
