package com.ersingundem.larenor.window

enum class WindowProfile { adaptive, panel }

data class WindowEnvironment(
    val resumed: Boolean = false,
    val focused: Boolean = false,
    val multiWindow: Boolean = false,
    val pictureInPicture: Boolean = false,
    val externalDisplay: Boolean = false,
    val displayKnown: Boolean = false,
    val displayId: Int? = null,
    val displayRevision: Long? = null,
    val desktopMode: Boolean = false,
    val captionVisible: Boolean? = null,
    val imeVisible: Boolean? = null,
    val statusBarVisible: Boolean? = null,
    val navigationBarVisible: Boolean? = null,
    val lockTaskPermitted: Boolean? = null,
    val lockTaskState: String = "unknown",
)

data class WindowDecision(val mode: String, val reason: String, val hide: Boolean = false)

/** Process-local logical-display incarnation fence; it is not hardware identity. */
internal class WindowDisplayGeneration {
    private val generations = mutableMapOf<Int, Long>()

    @Synchronized
    fun current(displayId: Int): Long {
        require(displayId >= 0)
        return generations.getOrPut(displayId) { 1L }
    }

    @Synchronized
    fun lifecycle(displayId: Int): Long {
        require(displayId >= 0)
        val current = generations[displayId] ?: 0L
        val next = if (current >= MAX_REVISION) 1L else current + 1L
        generations[displayId] = next
        return next
    }

    private companion object {
        const val MAX_REVISION = 9_007_199_254_740_991L
    }
}

object WindowPolicy {
    fun decide(profile: WindowProfile, env: WindowEnvironment, imeSettling: Boolean = false): WindowDecision {
        if (profile == WindowProfile.adaptive) return WindowDecision("adaptive", "none")
        val reason = when {
            !env.resumed -> "notForeground"
            !env.focused -> "noFocus"
            env.pictureInPicture -> "pictureInPicture"
            env.multiWindow -> "multiWindow"
            env.externalDisplay -> "externalDisplay"
            env.desktopMode -> "desktopMode"
            env.captionVisible == true -> "captionBar"
            env.imeVisible == true || imeSettling -> "keyboard"
            !env.displayKnown || env.captionVisible == null || env.imeVisible == null -> "unknown"
            else -> null
        }
        return when (reason) {
            null -> WindowDecision("panelRequested", "none", true)
            "unknown" -> WindowDecision("unknown", reason)
            else -> WindowDecision("restricted", reason)
        }
    }
}

fun interface WindowCancellation { fun cancel() }
interface WindowPolicyHost {
    fun readEnvironment(): WindowEnvironment
    fun setBarsHidden(hidden: Boolean)
    fun nowMillis(): Long
    fun schedule(delayMillis: Long, callback: () -> Unit): WindowCancellation
}

/** One Activity owner; delayed work never restores an obsolete profile. */
class WindowPolicyController(private val host: WindowPolicyHost) {
    private var profile = WindowProfile.adaptive
    private data class FullscreenOwner(
        val owner: String, val revision: Long, val displayId: Int, val displayRevision: Long,
    )
    private var fullscreen: FullscreenOwner? = null
    private var fullscreenRevision = 0L
    private var previousIme: Boolean? = null
    private var imeReleaseAt = 0L
    private var pending: WindowCancellation? = null
    private var lastRequested: Boolean? = null
    private var applicationFailed = false
    private var disposed = false
    private var lastEmitted: Map<String, Any?>? = null
    var onChanged: ((Map<String, Any?>) -> Unit)? = null

    fun setProfile(raw: Any?): Map<String, Any?> {
        require(raw is Map<*, *> && raw.size == 1 && raw.containsKey("profile"))
        val next = when (raw["profile"]) {
            "adaptive" -> WindowProfile.adaptive
            "panel" -> WindowProfile.panel
            else -> throw IllegalArgumentException("Invalid window profile")
        }
        if (!disposed) {
            fullscreen = null
            profile = next
            refresh(force = true)
        }
        return snapshot()
    }

    private fun environment(): WindowEnvironment = try {
        host.readEnvironment()
    } catch (_: RuntimeException) { WindowEnvironment() }

    /** Does not apply policy, launch settings, or enter lock task. */
    fun snapshot(): Map<String, Any?> {
        val env = environment()
        // A read retires lost logical ownership without applying a window request.
        // Returning to the same display must not revive a previously lost owner.
        retireFullscreen(env)
        return packet(env)
    }

    /** Transient request owned by one caller and one logical display incarnation. */
    fun acquireFullscreen(raw: Any?): Map<String, Any?> {
        require(raw is Map<*, *> && raw.keys == setOf("owner", "displayId", "displayRevision"))
        val owner = fullscreenOwner(raw["owner"])
        val displayId = raw["displayId"] as? Int ?: throw IllegalArgumentException()
        val displayRevision = when (val value = raw["displayRevision"]) {
            is Int -> value.toLong()
            is Long -> value
            else -> throw IllegalArgumentException()
        }
        require(displayId >= 0 && displayRevision in 1..9_007_199_254_740_991L)
        val env = environment()
        val hadFullscreen = fullscreen != null
        retireFullscreen(env)
        if (hadFullscreen && fullscreen == null) refresh(force = true)
        val previous = fullscreen
        var accepted = !disposed && ownsDisplay(env, displayId, displayRevision) &&
            WindowPolicy.decide(WindowProfile.panel, env, host.nowMillis() < imeReleaseAt).hide &&
            (previous == null || previous.owner == owner)
        if (accepted && previous == null) {
            if (fullscreenRevision == 9_007_199_254_740_991L) accepted = false
            else fullscreen = FullscreenOwner(owner, ++fullscreenRevision, displayId, displayRevision)
        }
        if (accepted) {
            refresh(force = previous == null)
            if (applicationFailed || fullscreen?.owner != owner) {
                fullscreen = null
                refresh(force = true)
                accepted = false
            }
        }
        var finalSnapshot = snapshot()
        if (accepted && fullscreen?.owner != owner) {
            accepted = false
            refresh(force = true)
            finalSnapshot = snapshot()
        }
        return mapOf("schemaVersion" to 1, "accepted" to accepted,
            "revision" to if (accepted) fullscreen?.revision else null, "snapshot" to finalSnapshot)
    }

    fun releaseFullscreen(raw: Any?): Boolean {
        require(raw is Map<*, *> && raw.keys == setOf("owner", "revision"))
        val owner = fullscreenOwner(raw["owner"])
        val revision = when (val value = raw["revision"]) {
            is Int -> value.toLong()
            is Long -> value
            else -> throw IllegalArgumentException()
        }
        require(revision in 1..9_007_199_254_740_991L)
        if (disposed || fullscreen?.owner != owner || fullscreen?.revision != revision) return false
        fullscreen = null
        refresh(force = true)
        return true
    }

    /** An unreadable acquisition reply may only retire its unique caller nonce. */
    fun cancelFullscreen(raw: Any?): Boolean {
        require(raw is Map<*, *> && raw.keys == setOf("owner"))
        val owner = fullscreenOwner(raw["owner"])
        if (disposed || fullscreen?.owner != owner) return false
        fullscreen = null
        refresh(force = true)
        return true
    }

    private fun fullscreenOwner(raw: Any?): String {
        require(raw is String && Regex("[0-9a-f]{32}").matches(raw))
        return raw
    }

    private fun ownsDisplay(env: WindowEnvironment, id: Int, revision: Long): Boolean =
        env.resumed && env.focused && env.displayKnown && env.displayId == id &&
            env.displayRevision == revision && !env.multiWindow && !env.pictureInPicture &&
            !env.externalDisplay && !env.desktopMode && env.captionVisible == false &&
            env.imeVisible != null

    private fun retireFullscreen(env: WindowEnvironment) {
        val current = fullscreen ?: return
        if (!ownsDisplay(env, current.displayId, current.displayRevision)) fullscreen = null
    }

    private fun effectiveProfile(env: WindowEnvironment): WindowProfile =
        if (fullscreen?.let { ownsDisplay(env, it.displayId, it.displayRevision) } == true)
            WindowProfile.panel else profile

    fun refresh(force: Boolean = false) {
        if (disposed) return
        val env = environment()
        retireFullscreen(env)
        if (previousIme == true && env.imeVisible == false) imeReleaseAt = host.nowMillis() + 1100
        if (env.imeVisible == true) imeReleaseAt = 0
        previousIme = env.imeVisible
        val settling = host.nowMillis() < imeReleaseAt
        val decision = WindowPolicy.decide(effectiveProfile(env), env, settling)
        // A profile/lifecycle change can cancel the pending work. The callback
        // reads current policy again instead of capturing an old hide request.
        if (settling && effectiveProfile(env) == WindowProfile.panel && env.resumed && env.focused) {
            if (pending == null) pending = host.schedule(imeReleaseAt - host.nowMillis()) {
                pending = null
                refresh(force = true)
            }
        } else {
            pending?.cancel()
            pending = null
        }
        if (force || lastRequested != decision.hide) {
            lastRequested = decision.hide
            applicationFailed = try {
                host.setBarsHidden(decision.hide)
                false
            } catch (_: RuntimeException) { true }
        }
        val packet = packet(environment())
        if (packet != lastEmitted) {
            lastEmitted = packet
            onChanged?.invoke(packet)
        }
    }

    private fun packet(env: WindowEnvironment): Map<String, Any?> {
        val decision = WindowPolicy.decide(effectiveProfile(env), env, host.nowMillis() < imeReleaseAt)
        return mapOf(
            "supported" to true,
            "requestedProfile" to profile.name,
            "effectiveMode" to if (applicationFailed) "unknown" else decision.mode,
            "reason" to if (applicationFailed) "unknown" else decision.reason,
            "isResumed" to env.resumed,
            "hasWindowFocus" to env.focused,
            "isMultiWindow" to env.multiWindow,
            "isPictureInPicture" to env.pictureInPicture,
            "isExternalDisplay" to env.externalDisplay,
            "displayId" to env.displayId,
            "displayRevision" to env.displayRevision,
            "captionVisible" to env.captionVisible,
            "imeVisible" to env.imeVisible,
            "statusBarVisible" to env.statusBarVisible,
            "navigationBarVisible" to env.navigationBarVisible,
            "lockTaskPermitted" to env.lockTaskPermitted,
            "lockTaskState" to env.lockTaskState,
        )
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        fullscreen = null
        pending?.cancel()
        pending = null
        onChanged = null
        // Only our own window is affected; no system/global setting persists.
        try { host.setBarsHidden(false) } catch (_: RuntimeException) { }
    }
}
