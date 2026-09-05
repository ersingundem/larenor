package com.ersingundem.larenor.kiosk

/** Only our own package is editable. No enrollment, user restrictions or device wipe. */
enum class KioskAction { allowApp, removeApp, restorePowerMenu, enter, exit }

data class KioskState(
    val deviceOwner: Boolean?,
    val permitted: Boolean?,
    val lockState: String,
    val resumed: Boolean,
    val focused: Boolean,
    val eligibleWindow: Boolean,
    val keyguardLocked: Boolean?,
    val powerMenuAllowed: Boolean?,
    val allowlistCount: Int?,
) {
    val interactive get() = resumed && focused
    fun permits(action: KioskAction): Boolean = interactive && when (action) {
        KioskAction.allowApp -> deviceOwner == true && permitted == false && eligibleWindow
        KioskAction.removeApp -> deviceOwner == true && permitted == true
        KioskAction.restorePowerMenu -> deviceOwner == true && powerMenuAllowed == false
        KioskAction.enter -> eligibleWindow && deviceOwner != null && permitted == true && lockState == "none" &&
            keyguardLocked == false && (deviceOwner != true || powerMenuAllowed == true)
        // Exit deliberately does not require allowlist, primary display or current owner rights.
        KioskAction.exit -> lockState == "locked" || lockState == "pinned"
    }
    fun toMap(): Map<String, Any?> = mapOf(
        "supported" to true, "deviceOwner" to deviceOwner, "permitted" to permitted,
        "lockState" to lockState, "resumed" to resumed, "focused" to focused,
        "eligibleWindow" to eligibleWindow, "keyguardLocked" to keyguardLocked,
        "powerMenuAllowed" to powerMenuAllowed, "allowlistCount" to allowlistCount,
        "actions" to KioskAction.entries.filter { permits(it) }.map { it.name },
    )
}

interface KioskHost {
    fun read(): KioskState
    fun apply(action: KioskAction)
    fun nowMillis(): Long
    fun token(): String
}
class KioskFailure(val code: String) : RuntimeException("Kiosk action unavailable")

/** A one-use proposal; invalidated by native background/focus and Flutter interaction expiry. */
class KioskPolicy(private val host: KioskHost) {
    private data class Intent(val id: String, val action: KioskAction, val state: KioskState, val epoch: Long, val expires: Long)
    private var pending: Intent? = null
    private var epoch = 0L
    private var busy = false
    private var disposed = false
    fun invalidate() { epoch++; pending = null }
    fun snapshot(): Map<String, Any?> { checkAlive(); return host.read().toMap() }
    fun prepare(raw: Any?): Map<String, Any?> {
        checkAlive()
        if (pending?.let { host.nowMillis() >= it.expires } == true) pending = null
        if (busy || pending != null) throw KioskFailure("busy")
        val map = raw as? Map<*, *> ?: throw KioskFailure("invalid")
        if (map.size != 1) throw KioskFailure("invalid")
        val action = KioskAction.entries.firstOrNull { it.name == map["action"] } ?: throw KioskFailure("invalid")
        val state = host.read()
        if (!state.permits(action)) throw KioskFailure("denied")
        val id = host.token()
        pending = Intent(id, action, state, epoch, host.nowMillis() + 30_000L)
        return mapOf("id" to id, "action" to action.name, "snapshot" to state.toMap())
    }
    fun cancel(raw: Any?) {
        val id = argumentToken(raw)
        if (pending?.id == id) pending = null
    }
    fun execute(raw: Any?): Map<String, Any?> {
        checkAlive()
        if (busy) throw KioskFailure("busy")
        val id = argumentToken(raw)
        val intent = pending ?: throw KioskFailure("expired")
        if (intent.id != id) throw KioskFailure("expired")
        pending = null // Consume before reads, permissions or any native side effect.
        if (intent.epoch != epoch || host.nowMillis() >= intent.expires) throw KioskFailure("expired")
        val before = host.read()
        if (before != intent.state || !before.permits(intent.action)) throw KioskFailure("expired")
        busy = true
        return try {
            host.apply(intent.action)
            val after = host.read()
            val observed = when (intent.action) {
                KioskAction.allowApp -> after.permitted == true
                KioskAction.removeApp -> after.permitted == false
                KioskAction.restorePowerMenu -> after.powerMenuAllowed == true
                KioskAction.enter -> after.lockState == "locked"
                KioskAction.exit -> after.lockState == "none"
            }
            mapOf("outcome" to if (observed) "observed" else "accepted", "snapshot" to after.toMap())
        } catch (_: SecurityException) {
            throw KioskFailure("denied")
        } catch (_: RuntimeException) {
            // The OS operation may already have been accepted. Never replay it.
            mapOf("outcome" to "unknown", "snapshot" to safeSnapshot())
        } finally { busy = false }
    }
    private fun safeSnapshot(): Map<String, Any?>? = try { host.read().toMap() } catch (_: RuntimeException) { null }
    private fun argumentToken(raw: Any?): String {
        val map = raw as? Map<*, *> ?: throw KioskFailure("invalid")
        val id = map["id"] as? String ?: throw KioskFailure("invalid")
        if (map.size != 1 || !Regex("[a-zA-Z0-9-]{16,80}").matches(id)) throw KioskFailure("invalid")
        return id
    }
    private fun checkAlive() { if (disposed) throw KioskFailure("unavailable") }
    fun dispose() { disposed = true; invalidate() }
}
