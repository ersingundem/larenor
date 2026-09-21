package com.ersingundem.larenor.display

import org.junit.Assert.*
import org.junit.Test

class DualDisplayContractTest {
    @Test
    fun exactPublicPresentationAndDismissalAreSingleOwner() {
        val host = FakeHost()
        val controller = DualDisplayController(host)
        controller.setResumed(true)
        controller.setFocused(true)
        val request = mapOf(
            "sessionId" to "display-session-1-7-4",
            "topologyRevision" to 7L,
            "displayId" to 4,
            "displayGeneration" to 5L,
            "routeId" to "media.now-playing",
        )
        assertEquals(request + ("attached" to true), controller.present(request))
        assertEquals(1, host.presented.size)
        assertEquals(null, controller.dismiss(mapOf(
            "sessionId" to "display-session-1-7-4",
            "displayId" to 4,
        )))
        assertEquals(listOf(4), host.dismissed)
    }

    @Test
    fun lifecycleStaleAndPrivateRequestsFailBeforeHost() {
        val host = FakeHost()
        val controller = DualDisplayController(host)
        val valid = mapOf(
            "sessionId" to "display-session-1-7-4",
            "topologyRevision" to 7L,
            "displayId" to 4,
            "displayGeneration" to 5L,
            "routeId" to "media.now-playing",
        )
        for (bad in listOf(
            valid,
            valid + ("routeId" to "admin.secrets"),
            valid + ("displayGeneration" to 4L),
            valid + ("credential" to "must-not-cross"),
        )) {
            try {
                controller.present(bad)
                fail("Unsafe presentation was accepted")
            } catch (_: DualDisplayFailure) {}
        }
        controller.setResumed(true)
        controller.setFocused(true)
        controller.setFocused(false)
        try {
            controller.present(valid)
            fail("Inactive presentation was accepted")
        } catch (_: DualDisplayFailure) {}
        assertTrue(host.presented.isEmpty())
    }

    @Test
    fun duplicateIntentIsIdempotentAndForeignDismissalCannotRetireIt() {
        val host = FakeHost()
        val controller = DualDisplayController(host)
        controller.setResumed(true)
        controller.setFocused(true)
        val request = mapOf(
            "sessionId" to "display-session-1-7-4",
            "topologyRevision" to 7L,
            "displayId" to 4,
            "displayGeneration" to 5L,
            "routeId" to "dashboard.overview",
        )

        val first = controller.present(request)
        assertEquals(first, controller.present(request))
        assertEquals(1, host.presented.size)
        try {
            controller.dismiss(mapOf(
                "sessionId" to "display-session-2-7-4",
                "displayId" to 4,
            ))
            fail("Foreign session retired the active presentation")
        } catch (_: DualDisplayFailure) {}
        assertTrue(host.dismissed.isEmpty())
        controller.setFocused(false)
        assertEquals(listOf(4), host.dismissed)
    }

    private class FakeHost : DualDisplayHost {
        val presented = mutableListOf<DualDisplayRequest>()
        val dismissed = mutableListOf<Int>()
        override fun topology() = DualDisplayTopology(
            revision = 7,
            surfaces = listOf(
                DualDisplaySurface(0, 3, true, 1600, 2560, 320, true),
                DualDisplaySurface(4, 5, false, 1920, 1080, 160, true),
            ),
        )
        override fun present(request: DualDisplayRequest): Boolean {
            presented += request
            return true
        }
        override fun dismiss(displayId: Int) { dismissed += displayId }
    }
}
