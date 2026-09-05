package com.ersingundem.larenor.window

enum class WindowProfile { adaptive, panel }

data class WindowEnvironment(
    val resumed: Boolean = false,
    val focused: Boolean = false,
    val multiWindow: Boolean = false,
    val pictureInPicture: Boolean = false,
    val externalDisplay: Boolean = false,
    val displayKnown: Boolean = false,
    val desktopMode: Boolean = false,
    val captionVisible: Boolean? = null,
    val imeVisible: Boolean? = null,
    val statusBarVisible: Boolean? = null,
    val navigationBarVisible: Boolean? = null,
    val lockTaskPermitted: Boolean? = null,
    val lockTaskState: String = "unknown",
)

data class WindowDecision(val mode: String, val reason: String, val hide: Boolean = false)

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
            profile = next
            refresh(force = true)
        }
        return snapshot()
    }

    private fun environment(): WindowEnvironment = try {
        host.readEnvironment()
    } catch (_: RuntimeException) { WindowEnvironment() }

    /** Does not apply policy, launch settings, or enter lock task. */
    fun snapshot(): Map<String, Any?> = packet(environment())

    fun refresh(force: Boolean = false) {
        if (disposed) return
        val env = environment()
        if (previousIme == true && env.imeVisible == false) imeReleaseAt = host.nowMillis() + 1100
        if (env.imeVisible == true) imeReleaseAt = 0
        previousIme = env.imeVisible
        val settling = host.nowMillis() < imeReleaseAt
        val decision = WindowPolicy.decide(profile, env, settling)
        // A profile/lifecycle change can cancel the pending work. The callback
        // reads current policy again instead of capturing an old hide request.
        if (settling && profile == WindowProfile.panel && env.resumed && env.focused) {
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
        val decision = WindowPolicy.decide(profile, env, host.nowMillis() < imeReleaseAt)
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
        pending?.cancel()
        pending = null
        onChanged = null
        // Only our own window is affected; no system/global setting persists.
        try { host.setBarsHidden(false) } catch (_: RuntimeException) { }
    }
}
