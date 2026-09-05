package com.ersingundem.larenor.wellbeing

interface WellbeingSecureWindow {
    fun isSecure(): Boolean
    fun setSecure(value: Boolean)
}

/** Retains protection over the last private frame in Recents until the visible
 * masked replacement explicitly releases it. Other pre-existing owners remain. */
class WellbeingPrivateView(private val window: WellbeingSecureWindow,
    private val foreground: () -> Boolean) {
    private var owned = false
    private var claimed = false
    private var disposed = false
    val active: Boolean get() = !disposed && claimed && foreground() && window.isSecure()
    fun setPrivate(value: Boolean) {
        check(!disposed)
        if (value) {
            check(foreground())
            if (!window.isSecure()) {
                window.setSecure(true)
                owned = true
            }
            check(window.isSecure())
            claimed = true
        } else {
            claimed = false
            if (owned && foreground()) {
                window.setSecure(false)
                owned = false
            }
        }
    }
    fun background() { claimed = false }
    fun dispose() {
        if (disposed) return
        try { setPrivate(false) } catch (_: RuntimeException) { }
        disposed = true
    }
}
