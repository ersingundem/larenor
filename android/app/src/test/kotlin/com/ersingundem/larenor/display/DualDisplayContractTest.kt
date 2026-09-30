package com.ersingundem.larenor.display

import org.junit.Assert.*
import org.junit.Test

class DualDisplayContractTest {
    private fun snapshot(revision: Long = 101L) = mapOf(
        "schemaVersion" to 1,
        "snapshotRevision" to revision,
        "observedAtMs" to 1_000L,
        "expiresAtMs" to 16_000L,
        "serviceState" to "online",
        "apiVersion" to 1,
        "systemLoadPercent" to 12,
        "processMemoryMiB" to 128,
        "dataDiskFreeBytes" to 400L,
        "dataDiskTotalBytes" to 1_000L,
        "processUptimeSeconds" to 30L,
    )

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
            "routeId" to "core.status",
            "publicSnapshot" to snapshot(),
        )
        assertEquals(
            request.filterKeys { it != "publicSnapshot" } + ("attached" to true),
            controller.present(request),
        )
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
            "routeId" to "core.status",
            "publicSnapshot" to snapshot(),
        )
        for (bad in listOf(
            valid,
            valid + ("routeId" to "admin.secrets"),
            valid + ("displayGeneration" to 4L),
            valid + ("credential" to "must-not-cross"),
            valid + ("publicSnapshot" to (snapshot() + ("token" to "forbidden"))),
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
            "routeId" to "core.status",
            "publicSnapshot" to snapshot(),
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
        var accepted = false
        controller.publish(mapOf(
            "sessionId" to "display-session-1-7-4",
            "displayId" to 4,
            "publicSnapshot" to snapshot(102L),
        )) { accepted = it }
        assertTrue(accepted)
        assertEquals(1, host.published.size)
        controller.publish(mapOf(
            "sessionId" to "display-session-1-7-4",
            "displayId" to 4,
            "publicSnapshot" to snapshot(102L),
        )) { accepted = it }
        assertTrue(accepted)
        assertEquals(1, host.published.size)
        try {
            controller.publish(mapOf(
                "sessionId" to "display-session-1-7-4",
                "displayId" to 4,
                "publicSnapshot" to snapshot(101L),
            )) { accepted = it }
            fail("Stale public snapshot was accepted")
        } catch (_: DualDisplayFailure) {}
        controller.setFocused(false)
        assertEquals(listOf(4), host.dismissed)
    }

    @Test
    fun topologyChangeRetiresOldOwnerBeforeReattachedDisplayCanPresent() {
        val host = FakeHost()
        val controller = DualDisplayController(host)
        controller.setResumed(true)
        controller.setFocused(true)
        val old = mapOf(
            "sessionId" to "display-session-1-7-4",
            "topologyRevision" to 7L,
            "displayId" to 4,
            "displayGeneration" to 5L,
            "routeId" to "core.status",
            "publicSnapshot" to snapshot(),
        )
        assertEquals(true, controller.present(old)["attached"])

        host.currentTopology = DualDisplayTopology(
            revision = 8,
            surfaces = listOf(DualDisplaySurface(0, 3, true, 1600, 2560, 320, true)),
        )
        controller.snapshot()
        assertEquals(listOf(4), host.dismissed)

        host.currentTopology = DualDisplayTopology(
            revision = 9,
            surfaces = listOf(
                DualDisplaySurface(0, 3, true, 1600, 2560, 320, true),
                DualDisplaySurface(4, 6, false, 1920, 1080, 160, true),
            ),
        )
        val reattached = old + mapOf(
            "sessionId" to "display-session-2-9-4",
            "topologyRevision" to 9L,
            "displayGeneration" to 6L,
        )
        assertEquals(true, controller.present(reattached)["attached"])
        assertEquals(2, host.presented.size)
    }

    private class FakeHost : DualDisplayHost {
        val presented = mutableListOf<DualDisplayRequest>()
        val dismissed = mutableListOf<Int>()
        val published = mutableListOf<DualDisplayPublicUpdate>()
        var currentTopology = DualDisplayTopology(
            revision = 7,
            surfaces = listOf(
                DualDisplaySurface(0, 3, true, 1600, 2560, 320, true),
                DualDisplaySurface(4, 5, false, 1920, 1080, 160, true),
            ),
        )
        override fun topology() = currentTopology
        override fun present(request: DualDisplayRequest): Boolean {
            presented += request
            return true
        }
        override fun dismiss(displayId: Int) { dismissed += displayId }
        override fun publish(update: DualDisplayPublicUpdate, completion: (Boolean) -> Unit) {
            published += update
            completion(true)
        }
    }
}
