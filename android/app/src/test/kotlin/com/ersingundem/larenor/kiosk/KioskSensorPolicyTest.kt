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
        override fun availability() = KioskSensorAvailability(light = true, motion = true, camera = camera)
        override fun start(listener: (KioskSensorSample) -> Unit) { started++; this.listener = listener }
        override fun stop() { stopped++; listener = null }
        override fun nowMillis() = now
        override fun token() = "123e4567-e89b-12d3-a456-426614174000"
        fun emit(sample: KioskSensorSample) = listener?.invoke(sample)
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

    @Test fun samplesAreThrottledBoundedAndCarryNoRawHistory() {
        val host = Host(); val policy = KioskSensorPolicy(host); policy.setInteractive(true)
        val started = policy.start(mapOf("intervalMillis" to 1000)); val id = started["sessionId"]
        host.emit(KioskSensorSample.Light(10.0, 1000))
        host.emit(KioskSensorSample.Light(20.0, 1500))
        host.emit(KioskSensorSample.Motion(0.8, 1000))
        host.emit(KioskSensorSample.Motion(Double.NaN, 3000))
        val read = policy.read(mapOf("sessionId" to id))
        assertEquals(10.0, read["lux"]); assertEquals(0.8, read["motionDelta"])
        assertEquals(2L, read["sequence"]); assertEquals(10, read.size)
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
}
