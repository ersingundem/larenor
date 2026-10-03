package com.ersingundem.larenor.rdp.packaged

import android.app.Application
import com.ersingundem.larenor.rdp.RdpRemoteAudioObservation
import com.ersingundem.larenor.rdp.RdpRemoteAudioState
import com.freerdp.freerdpcore.services.LibFreeRDP
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpPackagedRemoteAudioContractTest {
    @Test
    fun uriEnablesOpenSlOnlyForExplicitAudioRequests() {
        val enabled = packagedConnectionUri(
            "fixture.invalid", 3389, "fixture", 1280, 800, false,
            audio = true,
        )
        val disabled = packagedConnectionUri(
            "fixture.invalid", 3389, "fixture", 1280, 800, false,
            audio = false,
        )

        assertEquals("0", enabled.getQueryParameter("audio-mode"))
        assertEquals("sys:opensles", enabled.getQueryParameter("sound"))
        assertEquals("2", disabled.getQueryParameter("audio-mode"))
        assertNull(disabled.getQueryParameter("sound"))
    }

    @Test
    fun exactInstanceCountersAndLifecycleProduceBoundedObservations() {
        val gate = RdpRemoteAudioGate(expectedInstance = 41, requested = true)

        assertEquals(
            RdpRemoteAudioGate.Update.Ignored,
            gate.observe(42, true, 0, 0, LibFreeRDP.REMOTE_AUDIO_DEVICE_OPENED),
        )
        assertAccepted(
            gate.observe(41, true, 0, 0, LibFreeRDP.REMOTE_AUDIO_DEVICE_OPENED),
            RdpRemoteAudioObservation(RdpRemoteAudioState.DEVICE_OPEN, true, 0, 0),
        )
        assertAccepted(
            gate.observe(41, true, 1, 0, LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED),
            RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 1, 0),
        )
        assertEquals(
            RdpRemoteAudioGate.Update.Ignored,
            gate.observe(41, true, 1, 0, LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED),
        )
        assertAccepted(
            gate.observe(41, true, 1, 1, LibFreeRDP.REMOTE_AUDIO_BUFFER_COMPLETED),
            RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 1, 1),
        )
        assertAccepted(
            gate.observe(41, false, 1, 1, LibFreeRDP.REMOTE_AUDIO_DEVICE_CLOSED),
            RdpRemoteAudioObservation(RdpRemoteAudioState.CLOSED, false, 1, 1),
        )
        assertAccepted(
            gate.observe(41, true, 1, 1, LibFreeRDP.REMOTE_AUDIO_DEVICE_OPENED),
            RdpRemoteAudioObservation(RdpRemoteAudioState.DEVICE_OPEN, true, 1, 1),
        )
        assertEquals(
            RdpRemoteAudioGate.Update.Invalid,
            gate.observe(41, true, 1, 1, LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED),
        )
        assertEquals(
            RdpRemoteAudioGate.Update.Invalid,
            gate.observe(41, true, 2, 0, LibFreeRDP.REMOTE_AUDIO_BUFFER_COMPLETED),
        )
        assertEquals(
            RdpRemoteAudioGate.Update.Invalid,
            gate.observe(
                41, false, 9_007_199_254_740_992L, 1,
                LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED,
            ),
        )
    }

    @Test
    fun disabledAndRetiredGatesHaveNoPublicEffectButRetainExactFinalClose() {
        val disabled = RdpRemoteAudioGate(expectedInstance = 41, requested = false)
        assertEquals(
            RdpRemoteAudioGate.Update.Ignored,
            disabled.observe(41, true, 1, 0, LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED),
        )
        assertEquals(RdpRemoteAudioObservation.PENDING, disabled.retainedForTest())

        val gate = RdpRemoteAudioGate(expectedInstance = 41, requested = true)
        assertAccepted(
            gate.observe(41, true, 0, 0, LibFreeRDP.REMOTE_AUDIO_DEVICE_OPENED),
            RdpRemoteAudioObservation(RdpRemoteAudioState.DEVICE_OPEN, true, 0, 0),
        )
        assertAccepted(
            gate.observe(41, true, 2, 1, LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED),
            RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 2, 1),
        )
        gate.retire()

        assertEquals(
            RdpRemoteAudioGate.Update.Ignored,
            gate.observe(41, false, 2, 1, LibFreeRDP.REMOTE_AUDIO_DEVICE_CLOSED),
        )
        assertEquals(
            RdpRemoteAudioObservation(RdpRemoteAudioState.CLOSED, false, 2, 1),
            gate.retainedForTest(),
        )
        assertEquals(
            RdpRemoteAudioGate.Update.Ignored,
            gate.observe(99, false, 9, 9, LibFreeRDP.REMOTE_AUDIO_DEVICE_CLOSED),
        )
        assertEquals(2L, gate.retainedForTest().acceptedCount)
    }

    @Test
    fun packageConstantsAndFailedStateAreExact() {
        assertEquals(1, LibFreeRDP.REMOTE_AUDIO_DEVICE_OPENED)
        assertEquals(2, LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED)
        assertEquals(3, LibFreeRDP.REMOTE_AUDIO_BUFFER_COMPLETED)
        assertEquals(4, LibFreeRDP.REMOTE_AUDIO_DEVICE_CLOSED)
        assertEquals(5, LibFreeRDP.REMOTE_AUDIO_FAILED)

        val gate = RdpRemoteAudioGate(expectedInstance = 41, requested = true)
        val update = gate.observe(41, false, 0, 0, LibFreeRDP.REMOTE_AUDIO_FAILED)
        assertAccepted(
            update,
            RdpRemoteAudioObservation(RdpRemoteAudioState.FAILED, false, 0, 0),
        )

        val exhausted = RdpRemoteAudioGate(expectedInstance = 42, requested = true)
        assertAccepted(
            exhausted.observe(
                42, true, RDP_JS_SAFE_MAX, RDP_JS_SAFE_MAX,
                LibFreeRDP.REMOTE_AUDIO_DEVICE_OPENED,
            ),
            RdpRemoteAudioObservation(
                RdpRemoteAudioState.DEVICE_OPEN, true, RDP_JS_SAFE_MAX, RDP_JS_SAFE_MAX,
            ),
        )
        assertAccepted(
            exhausted.observe(
                42, false, RDP_JS_SAFE_MAX, RDP_JS_SAFE_MAX,
                LibFreeRDP.REMOTE_AUDIO_FAILED,
            ),
            RdpRemoteAudioObservation(
                RdpRemoteAudioState.FAILED, false, RDP_JS_SAFE_MAX, RDP_JS_SAFE_MAX,
            ),
        )
    }

    private fun assertAccepted(
        update: RdpRemoteAudioGate.Update,
        expected: RdpRemoteAudioObservation,
    ) {
        assertTrue(update is RdpRemoteAudioGate.Update.Accepted)
        assertEquals(expected, (update as RdpRemoteAudioGate.Update.Accepted).observation)
    }

    companion object {
        private const val RDP_JS_SAFE_MAX = 9_007_199_254_740_991L
    }
}
