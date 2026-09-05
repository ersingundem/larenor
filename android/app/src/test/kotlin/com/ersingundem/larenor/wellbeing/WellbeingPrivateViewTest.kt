package com.ersingundem.larenor.wellbeing

import org.junit.Assert.*
import org.junit.Test

class WellbeingPrivateViewTest {
    private class Window(var secureBit: Boolean = false) : WellbeingSecureWindow {
        val writes = mutableListOf<Boolean>()
        override fun isSecure() = secureBit
        override fun setSecure(value: Boolean) { secureBit = value; writes.add(value) }
    }
    @Test fun foregroundClaimRequiredAndPreexistingSecureOwnerIsNeverCleared() {
        var foreground = false
        val window = Window(true)
        val guard = WellbeingPrivateView(window) { foreground }
        try { guard.setPrivate(true); fail("background claim") } catch (_: IllegalStateException) { }
        foreground = true
        guard.setPrivate(true)
        assertTrue(guard.active)
        guard.setPrivate(false)
        guard.dispose()
        assertTrue(window.secureBit)
        assertTrue(window.writes.isEmpty())
    }
    @Test fun backgroundInvalidatesAccessButKeepsLastPrivateFrameSecureUntilMaskedRelease() {
        var foreground = true
        val window = Window()
        val guard = WellbeingPrivateView(window) { foreground }
        assertFalse(guard.active)
        guard.setPrivate(true)
        assertTrue(window.secureBit)
        foreground = false
        guard.background()
        guard.setPrivate(false)
        assertFalse(guard.active)
        assertTrue(window.secureBit)
        foreground = true
        assertFalse(guard.active) // Resume alone cannot renew private access.
        assertTrue(window.secureBit)
        guard.setPrivate(false) // Caller has now rendered a visible locked frame.
        assertFalse(window.secureBit)
        assertEquals(listOf(true, false), window.writes)
        guard.setPrivate(true)
        guard.dispose()
        assertFalse(window.secureBit)
    }
    @Test fun backgroundDisposalDoesNotExposeItsCachedFrameOrChangeOtherWindows() {
        var foreground = true
        val window = Window()
        val guard = WellbeingPrivateView(window) { foreground }
        guard.setPrivate(true)
        foreground = false
        guard.background()
        guard.dispose()
        assertTrue(window.secureBit)
        assertFalse(guard.active)
        val replacement = Window()
        assertFalse(replacement.secureBit) // FLAG_SECURE is per Window, not global.
    }
}
