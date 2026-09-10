package com.ersingundem.larenor.music

import org.junit.Assert.*
import org.junit.Test

class CoreMusicSessionContractTest {
    private fun snapshot() = mapOf<String, Any?>(
        "sessionId" to "6".repeat(32), "playerRevision" to 11L,
        "title" to "Synthetic Song", "positionMs" to 37_000L,
        "durationMs" to 241_000L, "isPlaying" to true, "isGroup" to false,
        "canPlay" to true, "canPause" to true, "canNext" to true,
        "canPrevious" to true, "canSeek" to true, "canVolume" to true,
        "volumeLevel" to 32, "controlsAuthorized" to true,
    )

    @Test fun strictSnapshotContainsNoTargetEndpointOrCredential() {
        val parsed = CoreMusicSessionSnapshot.parse(snapshot())
        assertEquals("Synthetic Song", parsed.title)
        assertEquals(11L, parsed.playerRevision)
        assertTrue(parsed.controlsAuthorized)
        assertFalse(parsed.toString().contains("sessionId"))
        for (extra in listOf("targetId", "endpoint", "token", "provider")) {
            try {
                CoreMusicSessionSnapshot.parse(snapshot() + (extra to "private"))
                fail("accepted $extra")
            } catch (_: CoreMusicSessionRejected) { }
        }
    }

    @Test fun actionGateIsExactSingleFlightAndRetiresStaleOrOfflineState() {
        val gate = CoreMusicSessionActionGate()
        val active = CoreMusicSessionSnapshot.parse(snapshot())
        gate.publish(active)
        val first = gate.begin("6".repeat(32), 11, "next", null)
        assertEquals("next", first.action)
        assertFails { gate.begin("6".repeat(32), 11, "next", null) }
        gate.complete(active.copy(playerRevision = 13))
        assertFails { gate.begin("6".repeat(32), 11, "pause", null) }
        assertEquals("pause", gate.begin("6".repeat(32), 13, "pause", null).action)
        gate.failClosed()
        assertFails { gate.begin("6".repeat(32), 13, "play", null) }
    }

    private fun assertFails(block: () -> Unit) {
        try { block(); fail("expected rejection") }
        catch (_: CoreMusicSessionRejected) { }
    }
}
