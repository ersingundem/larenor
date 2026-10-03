package com.ersingundem.larenor.rdp.packaged

import android.Manifest
import android.app.Application
import com.ersingundem.larenor.rdp.RdpMicrophoneCaptureObservation
import com.ersingundem.larenor.rdp.RdpMicrophoneCaptureState
import com.freerdp.freerdpcore.services.LibFreeRDP
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Robolectric
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpPackagedMicrophoneContractTest {
    @Test
    fun microphoneAuthorityRequiresTheExactFocusedActivityAndRealPermission() {
        assertFalse(packagedMicrophoneAuthority(null))
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().visible()
            .windowFocusChanged(true)
        try {
            assertFalse(packagedMicrophoneAuthority(activity.get()))
            Shadows.shadowOf(activity.get().application).grantPermissions(Manifest.permission.RECORD_AUDIO)
            assertTrue(packagedMicrophoneAuthority(activity.get()))
            activity.windowFocusChanged(false)
            assertFalse(packagedMicrophoneAuthority(activity.get()))
        } finally {
            activity.pause().stop().destroy()
        }
        assertFalse(packagedMicrophoneAuthority(activity.get()))
    }

    @Test
    fun uriEnablesOpenSlCaptureOnlyForExplicitMicrophoneRequests() {
        val enabled = packagedConnectionUri(
            "fixture.invalid", 3389, "fixture", 1280, 800, false,
            audio = false, microphone = true,
        )
        val disabled = packagedConnectionUri(
            "fixture.invalid", 3389, "fixture", 1280, 800, false,
            audio = true, microphone = false,
        )

        assertEquals("sys:opensles", enabled.getQueryParameter("microphone"))
        assertNull(enabled.getQueryParameter("sound"))
        assertEquals("sys:opensles", disabled.getQueryParameter("sound"))
        assertNull(disabled.getQueryParameter("microphone"))
    }

    @Test
    fun exactInstanceCaptureAndSubmissionProduceMonotonicBoundedEvidence() {
        val gate = RdpPackagedMicrophoneGate(expectedInstance = 41, requested = true)

        assertEquals(
            RdpPackagedMicrophoneGate.Update.Ignored,
            gate.observe(42, true, 0, 0, LibFreeRDP.MICROPHONE_DEVICE_OPENED),
        )
        assertAccepted(gate.observe(
            41, true, 0, 0, LibFreeRDP.MICROPHONE_DEVICE_OPENED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.OPENED, true, 0, 0,
        ))
        assertAccepted(gate.observe(
            41, true, 1, 0, LibFreeRDP.MICROPHONE_BUFFER_CAPTURED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.CAPTURED, true, 1, 0,
        ))
        assertAccepted(gate.observe(
            41, true, 1, 1, LibFreeRDP.MICROPHONE_BUFFER_ACCEPTED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.SENT, true, 1, 1,
        ))
        assertAccepted(gate.observe(
            41, true, 2, 1, LibFreeRDP.MICROPHONE_BUFFER_CAPTURED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.CAPTURED, true, 2, 1,
        ))
        assertAccepted(gate.observe(
            41, true, 2, 2, LibFreeRDP.MICROPHONE_BUFFER_ACCEPTED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.SENT, true, 2, 2,
        ))
        assertAccepted(gate.observe(
            41, false, 2, 2, LibFreeRDP.MICROPHONE_DEVICE_CLOSED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.CLOSED, false, 2, 2,
        ))
        assertEquals(
            RdpPackagedMicrophoneGate.Update.Invalid,
            gate.observe(41, true, 2, 2, LibFreeRDP.MICROPHONE_DEVICE_OPENED),
        )
    }

    @Test
    fun disabledRetiredMalformedAndFailedCallbacksNeverForgeSubmission() {
        val disabled = RdpPackagedMicrophoneGate(expectedInstance = 41, requested = false)
        assertEquals(
            RdpPackagedMicrophoneGate.Update.Ignored,
            disabled.observe(41, true, 1, 1, LibFreeRDP.MICROPHONE_BUFFER_ACCEPTED),
        )
        assertEquals(RdpMicrophoneCaptureObservation.PENDING, disabled.retainedForTest())

        val malformed = RdpPackagedMicrophoneGate(expectedInstance = 41, requested = true)
        assertAccepted(malformed.observe(
            41, true, 0, 0, LibFreeRDP.MICROPHONE_DEVICE_OPENED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.OPENED, true, 0, 0,
        ))
        assertEquals(
            RdpPackagedMicrophoneGate.Update.Invalid,
            malformed.observe(41, true, 1, 1, LibFreeRDP.MICROPHONE_BUFFER_ACCEPTED),
        )
        assertEquals(
            RdpPackagedMicrophoneGate.Update.Invalid,
            malformed.observe(41, true, JS_SAFE_MAX + 1, 0, LibFreeRDP.MICROPHONE_BUFFER_CAPTURED),
        )

        val retired = RdpPackagedMicrophoneGate(expectedInstance = 51, requested = true)
        assertAccepted(retired.observe(
            51, true, 0, 0, LibFreeRDP.MICROPHONE_DEVICE_OPENED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.OPENED, true, 0, 0,
        ))
        retired.retire()
        assertEquals(
            RdpPackagedMicrophoneGate.Update.Ignored,
            retired.observe(51, false, 0, 0, LibFreeRDP.MICROPHONE_DEVICE_CLOSED),
        )
        assertEquals(RdpMicrophoneCaptureState.CLOSED, retired.retainedForTest().state)

        val failed = RdpPackagedMicrophoneGate(expectedInstance = 61, requested = true)
        assertAccepted(failed.observe(
            61, true, 0, 0, LibFreeRDP.MICROPHONE_DEVICE_OPENED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.OPENED, true, 0, 0,
        ))
        assertAccepted(failed.observe(
            61, false, 0, 0, LibFreeRDP.MICROPHONE_FAILED,
        ), RdpMicrophoneCaptureObservation(
            RdpMicrophoneCaptureState.FAILED, false, 0, 0,
        ))
    }

    @Test
    fun packageConstantsAreExact() {
        assertEquals(1, LibFreeRDP.MICROPHONE_DEVICE_OPENED)
        assertEquals(2, LibFreeRDP.MICROPHONE_BUFFER_CAPTURED)
        assertEquals(3, LibFreeRDP.MICROPHONE_BUFFER_ACCEPTED)
        assertEquals(4, LibFreeRDP.MICROPHONE_DEVICE_CLOSED)
        assertEquals(5, LibFreeRDP.MICROPHONE_FAILED)
    }

    private fun assertAccepted(
        update: RdpPackagedMicrophoneGate.Update,
        expected: RdpMicrophoneCaptureObservation,
    ) {
        assertTrue(update is RdpPackagedMicrophoneGate.Update.Accepted)
        assertEquals(expected, (update as RdpPackagedMicrophoneGate.Update.Accepted).observation)
    }

    companion object {
        private const val JS_SAFE_MAX = 9_007_199_254_740_991L
    }
}
