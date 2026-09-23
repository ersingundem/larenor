package com.ersingundem.larenor.kiosk

import org.junit.Assert.*
import org.junit.Test

class KioskSensorPolicyTest {
    private class Host : KioskSensorHost {
        var listener: ((KioskSensorSample) -> Unit)? = null
        var started = 0
        var stopped = 0
        var now = 1000L
        var camera = "available"
        var batteryPercent: Int? = 73
        var thermalStatus = "moderate"
        override fun availability() = KioskSensorAvailability(
            light = true,
            motion = true,
            approach = true,
            approachMaxRangeCm = 5.0,
            camera = camera,
            batteryPercent = batteryPercent,
            thermalStatus = thermalStatus,
        )
        override fun start(listener: (KioskSensorSample) -> Unit) { started++; this.listener = listener }
        override fun stop() { stopped++; listener = null }
        override fun nowMillis() = now
        override fun token() = "123e4567-e89b-12d3-a456-426614174000"
        fun emit(sample: KioskSensorSample) = listener?.invoke(sample)
    }

    private class InvalidTokenHost : KioskSensorHost by Host() {
        override fun token() = "------------------------------------"
    }

    private fun fails(code: String, action: () -> Unit) {
        try { action(); fail("Expected $code") } catch (error: KioskFailure) { assertEquals(code, error.code) }
    }

    @Test fun samplingRequiresForegroundFocusAndBoundedInterval() {
        val host = Host(); val policy = KioskSensorPolicy(host)
        fails("denied") { policy.start(mapOf("intervalMillis" to 1000)) }
        policy.setInteractive(true)
        for (value in listOf(999, 10001, "1000", null)) {
            fails("invalid") { policy.start(mapOf("intervalMillis" to value)) }
        }
        val started = policy.start(mapOf("intervalMillis" to 1000))
        assertEquals(true, started["sampling"]); assertEquals(1, host.started)
        fails("busy") { policy.start(mapOf("intervalMillis" to 1000)) }
        policy.setInteractive(false)
        assertEquals(1, host.stopped)
        fails("expired") { policy.read(mapOf("sessionId" to started["sessionId"])) }
    }

    @Test fun malformedNativeSessionTokenNeverStartsAnOwnedSession() {
        val policy = KioskSensorPolicy(InvalidTokenHost())
        policy.setInteractive(true)
        fails("unavailable") { policy.start(mapOf("intervalMillis" to 1000)) }
        assertFalse(policy.hasSession())
    }

    @Test fun samplesAreThrottledBoundedAndCarryNoRawHistory() {
        val host = Host(); val policy = KioskSensorPolicy(host); policy.setInteractive(true)
        val started = policy.start(mapOf("intervalMillis" to 1000)); val id = started["sessionId"]
        host.emit(KioskSensorSample.Light(10.0, 1000))
        host.emit(KioskSensorSample.Light(20.0, 1500))
        host.emit(KioskSensorSample.Motion(0.8, 1000))
        host.emit(KioskSensorSample.Motion(Double.NaN, 3000))
        val read = policy.read(mapOf("sessionId" to id))
        assertEquals(10.0, read["lux"]); assertEquals(0.8, read["motionDelta"])
        assertEquals(2L, read["sequence"])
        host.emit(KioskSensorSample.Approach(2.0, 1000))
        host.emit(KioskSensorSample.Approach(4.0, 1500))
        val approached = policy.read(mapOf("sessionId" to id))
        assertEquals(3L, approached["sequence"]); assertEquals(15, approached.size)
        assertEquals(2.0, approached["approachDistanceCm"])
        assertEquals(5.0, approached["approachMaxRangeCm"])
        assertFalse(approached.containsKey("faceId"))
        host.emit(KioskSensorSample.Approach(120.0, 3000))
        assertEquals(5.0, policy.read(mapOf("sessionId" to id))["approachDistanceCm"])
        host.emit(KioskSensorSample.Light(300000.0, 3000))
        assertEquals(200000.0, policy.read(mapOf("sessionId" to id))["lux"])
    }

    @Test fun exactSessionStopIsIdempotentOnlyThroughVerifiedReceipt() {
        val host = Host(); val policy = KioskSensorPolicy(host); policy.setInteractive(true)
        val id = policy.start(mapOf("intervalMillis" to 1000))["sessionId"]
        fails("expired") { policy.stop(mapOf("sessionId" to "00000000-0000-0000-0000-000000000000")) }
        val receipt = policy.stop(mapOf("sessionId" to id))
        assertEquals(mapOf("version" to 1, "sessionId" to id, "stopped" to true), receipt)
        assertEquals(1, host.stopped)
        fails("expired") { policy.stop(mapOf("sessionId" to id)) }
    }

    @Test fun cameraBusyAndPermissionRevocationStayExplicitWithoutOpeningCamera() {
        val host = Host(); val policy = KioskSensorPolicy(host); policy.setInteractive(true)
        val id = policy.start(mapOf("intervalMillis" to 1000))["sessionId"]
        assertEquals("available", policy.read(mapOf("sessionId" to id))["cameraStatus"])
        host.camera = "busy"
        assertEquals("busy", policy.read(mapOf("sessionId" to id))["cameraStatus"])
        host.camera = "permissionDenied"
        val denied = policy.read(mapOf("sessionId" to id))
        assertEquals("permissionDenied", denied["cameraStatus"])
        assertFalse(denied.containsKey("cameraFrame"))
        assertTrue(policy.hasSession())
    }

    @Test fun powerAndAvailabilityChangesAdvanceASecretFreeSnapshot() {
        val host = Host(); val policy = KioskSensorPolicy(host); policy.setInteractive(true)
        val started = policy.start(mapOf("intervalMillis" to 1000)); val id = started["sessionId"]
        assertEquals(3, started["version"])
        assertEquals(73, started["batteryPercent"])
        assertEquals("moderate", started["thermalStatus"])
        host.now = 2000L
        host.batteryPercent = 72
        host.thermalStatus = "severe"
        host.camera = "busy"
        val changed = policy.read(mapOf("sessionId" to id))
        assertEquals(1L, changed["sequence"])
        assertEquals(2000L, changed["observedAtElapsedMillis"])
        assertEquals(72, changed["batteryPercent"])
        assertEquals("severe", changed["thermalStatus"])
        assertFalse(changed.containsKey("temperature"))
        assertFalse(changed.containsKey("deviceId"))
        host.now = 3000L
        assertEquals(1L, policy.read(mapOf("sessionId" to id))["sequence"])
    }

    @Test fun powerAndThermalAvailabilityIsStrictlyBounded() {
        for (battery in listOf(-1, 101)) {
            try {
                KioskSensorAvailability(false, false, batteryPercent = battery)
                fail("Expected invalid battery")
            } catch (_: IllegalArgumentException) { }
        }
        try {
            KioskSensorAvailability(false, false, thermalStatus = "hot-secret")
            fail("Expected invalid thermal state")
        } catch (_: IllegalArgumentException) { }
    }
}
