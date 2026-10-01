package com.ersingundem.larenor.window

import org.junit.Assert.*
import org.junit.Test

class WindowFullscreenLeaseTest {
    private val owner = "a".repeat(32)
    private val other = "b".repeat(32)
    private val eligible = WindowEnvironment(resumed = true, focused = true,
        displayKnown = true, displayId = 0, displayRevision = 1,
        captionVisible = false, imeVisible = false,
        statusBarVisible = true, navigationBarVisible = true)
    private class Host(var env: WindowEnvironment) : WindowPolicyHost {
        val writes = mutableListOf<Boolean>()
        var fail = false
        var loseFocusDuringHide = false
        override fun readEnvironment() = env
        override fun setBarsHidden(hidden: Boolean) {
            writes.add(hidden)
            if (fail) throw IllegalStateException("private-window-error")
            if (hidden && loseFocusDuringHide) env = env.copy(focused = false)
        }
        override fun nowMillis() = 0L
        override fun schedule(delayMillis: Long, callback: () -> Unit) = WindowCancellation { }
    }
    private fun request(who: String = owner, revision: Long = 1L) =
        mapOf("owner" to who, "displayId" to 0, "displayRevision" to revision)

    @Test fun acquisitionKeepsUserPreferenceAndDoesNotInventObservedHiddenBars() {
        val host = Host(eligible)
        val controller = WindowPolicyController(host)
        val grant = controller.acquireFullscreen(request())
        assertEquals(true, grant["accepted"])
        assertEquals(1L, grant["revision"])
        assertEquals(listOf(true), host.writes)
        val snapshot = grant["snapshot"] as Map<*, *>
        assertEquals("adaptive", snapshot["requestedProfile"])
        assertEquals("panelRequested", snapshot["effectiveMode"])
        assertEquals(true, snapshot["statusBarVisible"])
        assertEquals("unknown", snapshot["lockTaskState"])
        assertFalse(snapshot.containsKey("owner"))
        assertEquals(grant, controller.acquireFullscreen(request()))
        assertEquals(listOf(true), host.writes) // No duplicate re-hide or swipe fight.
        assertEquals(false, controller.acquireFullscreen(request(other))["accepted"])
        assertEquals(listOf(true), host.writes)
    }

    @Test fun staleReleaseCannotRestoreBarsOverAReplacementOwner() {
        val host = Host(eligible)
        val controller = WindowPolicyController(host)
        controller.acquireFullscreen(request())
        assertFalse(controller.releaseFullscreen(mapOf("owner" to other, "revision" to 1)))
        assertFalse(controller.releaseFullscreen(mapOf("owner" to owner, "revision" to 2)))
        assertTrue(controller.releaseFullscreen(mapOf("owner" to owner, "revision" to 1)))
        assertEquals(listOf(true, false), host.writes)
        val second = controller.acquireFullscreen(request(other))
        assertEquals(2L, second["revision"])
        assertFalse(controller.cancelFullscreen(mapOf("owner" to owner)))
        assertFalse(controller.releaseFullscreen(mapOf("owner" to owner, "revision" to 1)))
        assertTrue(host.writes.last())
        assertTrue(controller.cancelFullscreen(mapOf("owner" to other)))
        assertFalse(host.writes.last())
    }

    @Test fun releaseRestoresTheCurrentUserPanelPreferenceInsteadOfAdaptive() {
        val host = Host(eligible)
        val controller = WindowPolicyController(host)
        controller.setProfile(mapOf("profile" to "panel"))
        controller.acquireFullscreen(request())
        assertTrue(controller.releaseFullscreen(mapOf("owner" to owner, "revision" to 1)))
        assertEquals("panel", controller.snapshot()["requestedProfile"])
        assertTrue(host.writes.last())
    }

    @Test fun everyOwnershipDriftRetiresWithoutRevivalOnResume() {
        val variants = listOf(eligible.copy(resumed = false), eligible.copy(focused = false),
            eligible.copy(displayRevision = 2), eligible.copy(displayId = 1),
            eligible.copy(multiWindow = true), eligible.copy(pictureInPicture = true),
            eligible.copy(externalDisplay = true), eligible.copy(desktopMode = true),
            eligible.copy(captionVisible = true), eligible.copy(displayKnown = false),
            eligible.copy(imeVisible = null))
        for (env in variants) {
            val host = Host(eligible)
            val controller = WindowPolicyController(host)
            controller.acquireFullscreen(request())
            host.env = env
            controller.refresh()
            assertFalse(host.writes.last())
            host.env = eligible
            controller.refresh()
            assertFalse(host.writes.last())
            assertFalse(controller.releaseFullscreen(mapOf("owner" to owner, "revision" to 1)))
        }
    }

    @Test fun readonlySnapshotObservingLossRetiresWithoutWritingOrReviving() {
        val host = Host(eligible)
        val controller = WindowPolicyController(host)
        controller.acquireFullscreen(request())
        host.env = eligible.copy(displayRevision = 2)
        controller.snapshot()
        assertEquals(listOf(true), host.writes) // Read is not an OS write.
        host.env = eligible
        controller.refresh()
        assertEquals(listOf(true, false), host.writes)
        assertFalse(controller.releaseFullscreen(mapOf("owner" to owner, "revision" to 1)))
    }

    @Test fun finalGrantObservationCannotReturnAnOwnerLostDuringApplication() {
        val host = Host(eligible).apply { loseFocusDuringHide = true }
        val controller = WindowPolicyController(host)
        val grant = controller.acquireFullscreen(request())
        assertEquals(false, grant["accepted"])
        assertNull(grant["revision"])
        assertFalse(host.writes.last())
        host.env = eligible
        controller.refresh()
        assertFalse(host.writes.last())
        assertFalse(controller.cancelFullscreen(mapOf("owner" to owner)))
    }

    @Test fun deniedAcquisitionCannotApplyBarsOrRevealAnotherOwnerRevision() {
        for (env in listOf(eligible.copy(imeVisible = true), eligible.copy(resumed = false),
            eligible.copy(focused = false), eligible.copy(displayRevision = null))) {
            val host = Host(env)
            val result = WindowPolicyController(host).acquireFullscreen(request())
            assertEquals(false, result["accepted"])
            assertNull(result["revision"])
            assertTrue(host.writes.isEmpty())
        }
    }

    @Test fun applyFailureDoesNotReturnAUsableLeaseOrExposePrivateError() {
        val host = Host(eligible).apply { fail = true }
        val controller = WindowPolicyController(host)
        val result = controller.acquireFullscreen(request())
        assertEquals(false, result["accepted"])
        assertNull(result["revision"])
        assertFalse(result.toString().contains("private"))
        assertFalse(controller.cancelFullscreen(mapOf("owner" to owner)))
    }

    @Test fun malformedInputsAreRejectedBeforeAnyWindowWrite() {
        val host = Host(eligible)
        val controller = WindowPolicyController(host)
        for (raw in listOf(null, "private", request("wrong"), request(revision = 0),
            request(revision = 9_007_199_254_740_992L), request() + ("extra" to "private"))) {
            try { controller.acquireFullscreen(raw); fail("invalid accepted") }
            catch (_: IllegalArgumentException) { }
        }
        assertTrue(host.writes.isEmpty())
    }

    @Test fun explicitPreferenceChangeAndDisposalRetireTheExactRequest() {
        for (dispose in listOf(false, true)) {
            val host = Host(eligible)
            val controller = WindowPolicyController(host)
            controller.acquireFullscreen(request())
            if (dispose) controller.dispose() else controller.setProfile(mapOf("profile" to "adaptive"))
            assertFalse(host.writes.last())
            assertFalse(controller.releaseFullscreen(mapOf("owner" to owner, "revision" to 1)))
            if (dispose) assertEquals(false, controller.acquireFullscreen(request())["accepted"])
        }
    }
}
