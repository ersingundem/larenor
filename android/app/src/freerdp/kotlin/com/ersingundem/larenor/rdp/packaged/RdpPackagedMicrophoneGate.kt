package com.ersingundem.larenor.rdp.packaged

import com.ersingundem.larenor.rdp.RdpMicrophoneCaptureObservation
import com.ersingundem.larenor.rdp.RdpMicrophoneCaptureState
import com.freerdp.freerdpcore.services.LibFreeRDP

/** Serializes exact-instance microphone capture facts without PCM or provider data. */
internal class RdpPackagedMicrophoneGate(
    private val expectedInstance: Long,
    private val requested: Boolean,
) {
    sealed interface Update {
        data class Accepted(val observation: RdpMicrophoneCaptureObservation) : Update
        data object Invalid : Update
        data object Ignored : Update
    }

    private var retired = false
    private var terminal = false
    private var latest = RdpMicrophoneCaptureObservation.PENDING

    @Synchronized fun observe(
        instance: Long,
        deviceOpen: Boolean,
        capturedCount: Long,
        acceptedCount: Long,
        fixedState: Int,
    ): Update {
        if (!requested || instance != expectedInstance) return Update.Ignored
        val state = when (fixedState) {
            LibFreeRDP.MICROPHONE_DEVICE_OPENED -> RdpMicrophoneCaptureState.OPENED
            LibFreeRDP.MICROPHONE_BUFFER_CAPTURED -> RdpMicrophoneCaptureState.CAPTURED
            LibFreeRDP.MICROPHONE_BUFFER_ACCEPTED -> RdpMicrophoneCaptureState.SENT
            LibFreeRDP.MICROPHONE_DEVICE_CLOSED -> RdpMicrophoneCaptureState.CLOSED
            LibFreeRDP.MICROPHONE_FAILED -> RdpMicrophoneCaptureState.FAILED
            else -> return Update.Invalid
        }
        val observation = try {
            RdpMicrophoneCaptureObservation(
                state, deviceOpen, capturedCount, acceptedCount,
            )
        } catch (_: RuntimeException) {
            return Update.Invalid
        }
        if (observation == latest) return Update.Ignored
        if (terminal) return Update.Invalid
        if (capturedCount < latest.capturedCount || acceptedCount < latest.acceptedCount) {
            return Update.Invalid
        }
        val causal = when (state) {
            RdpMicrophoneCaptureState.OPENED ->
                latest.state == RdpMicrophoneCaptureState.PENDING
            RdpMicrophoneCaptureState.CAPTURED ->
                latest.state in setOf(
                    RdpMicrophoneCaptureState.OPENED,
                    RdpMicrophoneCaptureState.CAPTURED,
                    RdpMicrophoneCaptureState.SENT,
                ) && capturedCount > latest.capturedCount
            RdpMicrophoneCaptureState.SENT ->
                latest.state == RdpMicrophoneCaptureState.CAPTURED &&
                    acceptedCount > latest.acceptedCount
            RdpMicrophoneCaptureState.CLOSED ->
                latest.state != RdpMicrophoneCaptureState.PENDING
            RdpMicrophoneCaptureState.FAILED -> true
            RdpMicrophoneCaptureState.PENDING -> false
        }
        if (!causal) return Update.Invalid
        if (retired) {
            if (state == RdpMicrophoneCaptureState.CLOSED) {
                latest = observation
                terminal = true
            }
            return Update.Ignored
        }
        latest = observation
        if (state in setOf(RdpMicrophoneCaptureState.CLOSED, RdpMicrophoneCaptureState.FAILED)) {
            terminal = true
        }
        return Update.Accepted(observation)
    }

    @Synchronized fun retire() {
        retired = true
    }

    @Synchronized fun retainedForTest(): RdpMicrophoneCaptureObservation = latest
}
