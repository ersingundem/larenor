package com.ersingundem.larenor.window

import org.junit.Assert.*
import org.junit.Test

class WindowPolicyTest {
    private val eligible = WindowEnvironment(resumed = true, focused = true,
        displayKnown = true, captionVisible = false, imeVisible = false,
        statusBarVisible = true, navigationBarVisible = true)
    private class Host(var env: WindowEnvironment) : WindowPolicyHost {
        var time = 0L
        var fail = false
        val writes = mutableListOf<Boolean>()
        data class Work(val at: Long, val task: () -> Unit, var cancelled: Boolean = false)
        val work = mutableListOf<Work>()
        override fun readEnvironment() = env
        override fun setBarsHidden(hidden: Boolean) {
            writes.add(hidden)
            if (fail) throw IllegalStateException("fixture-sensitive-device-error")
        }
        override fun nowMillis() = time
        override fun schedule(delayMillis: Long, callback: () -> Unit): WindowCancellation {
            val queued = Work(time + delayMillis, callback)
            work.add(queued)
            return WindowCancellation { queued.cancelled = true }
        }
        fun advance(ms: Long) {
            time += ms
            val due = work.filter { it.at <= time }
            work.removeAll(due.toSet())
            due.filterNot { it.cancelled }.forEach { it.task() }
        }
    }

    @Test fun defaultNeverHidesAndEveryRestrictionPreventsPanelHide() {
        val variants = listOf(
            eligible.copy(resumed = false) to "notForeground",
            eligible.copy(focused = false) to "noFocus",
            eligible.copy(pictureInPicture = true) to "pictureInPicture",
            eligible.copy(multiWindow = true) to "multiWindow",
            eligible.copy(externalDisplay = true) to "externalDisplay",
            eligible.copy(desktopMode = true) to "desktopMode",
            eligible.copy(captionVisible = true) to "captionBar",
            eligible.copy(imeVisible = true) to "keyboard",
            eligible.copy(displayKnown = false) to "unknown",
            eligible.copy(captionVisible = null) to "unknown",
            eligible.copy(imeVisible = null) to "unknown",
        )
        for ((env, reason) in variants) {
            assertFalse(WindowPolicy.decide(WindowProfile.adaptive, env).hide)
            assertEquals(reason, WindowPolicy.decide(WindowProfile.panel, env).reason)
            assertFalse(WindowPolicy.decide(WindowProfile.panel, env).hide)
        }
        assertTrue(WindowPolicy.decide(WindowProfile.panel, eligible).hide)
    }

    @Test fun snapshotAndControllerCreationAreReadOnlyAndMissingEvidenceStaysUnknown() {
        val host = Host(WindowEnvironment())
        val controller = WindowPolicyController(host)
        assertEquals("adaptive", controller.snapshot()["effectiveMode"])
        assertNull(controller.snapshot()["imeVisible"])
        assertNull(controller.snapshot()["lockTaskPermitted"])
        assertEquals("unknown", controller.snapshot()["lockTaskState"])
        assertTrue(host.writes.isEmpty())
        controller.setProfile(mapOf("profile" to "panel"))
        assertEquals(listOf(false), host.writes)
    }

    @Test fun acceptedHideDoesNotFabricateObservedBarsOrKioskAndUserSwipeIsNotFought() {
        val host = Host(eligible)
        val controller = WindowPolicyController(host)
        val snapshots = mutableListOf<Map<String, Any?>>()
        controller.onChanged = { snapshots.add(it) }
        val state = controller.setProfile(mapOf("profile" to "panel"))
        assertEquals("panelRequested", state["effectiveMode"])
        assertEquals(true, state["statusBarVisible"])
        assertEquals("unknown", state["lockTaskState"])
        repeat(100) { controller.refresh() }
        assertEquals(listOf(true), host.writes)
        assertEquals(1, snapshots.size)
        host.env = eligible.copy(statusBarVisible = false)
        controller.refresh()
        host.env = eligible // User edge-swipe restores bars; observation only.
        controller.refresh()
        assertEquals(listOf(true), host.writes)
        assertEquals(3, snapshots.size)
    }

    @Test fun keyboardCloseWaitsAndRechecksCurrentWindowBeforeRestoringPanel() {
        val host = Host(eligible)
        val controller = WindowPolicyController(host)
        controller.setProfile(mapOf("profile" to "panel"))
        host.env = eligible.copy(imeVisible = true)
        controller.refresh()
        host.env = eligible
        controller.refresh()
        assertEquals("keyboard", controller.snapshot()["reason"])
        host.advance(1099)
        assertEquals(listOf(true, false), host.writes)
        host.env = eligible.copy(multiWindow = true)
        host.advance(1)
        assertEquals("multiWindow", controller.snapshot()["reason"])
        assertFalse(host.writes.last())
        host.env = eligible
        controller.refresh()
        assertTrue(host.writes.last())
    }

    @Test fun lateKeyboardCallbackCannotReviveOldProfileOrDisposedActivity() {
        for (dispose in listOf(false, true)) {
            val host = Host(eligible.copy(imeVisible = true))
            val controller = WindowPolicyController(host)
            controller.setProfile(mapOf("profile" to "panel"))
            host.env = eligible
            controller.refresh()
            if (dispose) controller.dispose() else controller.setProfile(mapOf("profile" to "adaptive"))
            val before = host.writes.toList()
            host.advance(2000)
            controller.refresh(force = true)
            assertFalse(host.writes.contains(true))
            if (dispose) assertEquals(before, host.writes)
        }
    }

    @Test fun backgroundCancelsPendingRestoreAndResumeReevaluatesFocusedEnvironment() {
        val host = Host(eligible.copy(imeVisible = true))
        val controller = WindowPolicyController(host)
        controller.setProfile(mapOf("profile" to "panel"))
        host.env = eligible
        controller.refresh()
        host.env = eligible.copy(resumed = false)
        controller.refresh(force = true)
        host.advance(2000)
        assertFalse(host.writes.contains(true))
        host.env = eligible.copy(focused = false)
        controller.refresh(force = true)
        assertEquals("noFocus", controller.snapshot()["reason"])
        host.env = eligible
        controller.refresh(force = true)
        assertTrue(host.writes.last())
    }

    @Test fun invalidMethodPayloadCannotChangeProfileOrLeakRawInput() {
        val host = Host(eligible)
        val controller = WindowPolicyController(host)
        for (raw in listOf(null, "panel", mapOf("profile" to "kiosk"),
            mapOf("profile" to "panel", "token" to "fixture-private"))) {
            try { controller.setProfile(raw); fail("accepted invalid profile") }
            catch (_: IllegalArgumentException) { }
        }
        assertTrue(host.writes.isEmpty())
        assertEquals("adaptive", controller.snapshot()["requestedProfile"])
    }

    @Test fun failedNativeApplyReportsUnknownAndDoesNotSpinOnLayoutEvents() {
        val host = Host(eligible).apply { fail = true }
        val controller = WindowPolicyController(host)
        assertEquals("unknown", controller.setProfile(mapOf("profile" to "panel"))["effectiveMode"])
        repeat(100) { controller.refresh() }
        assertEquals(1, host.writes.size)
        assertFalse(controller.snapshot().toString().contains("sensitive"))
        host.fail = false
        controller.refresh(force = true)
        assertEquals("panelRequested", controller.snapshot()["effectiveMode"])
    }
}
