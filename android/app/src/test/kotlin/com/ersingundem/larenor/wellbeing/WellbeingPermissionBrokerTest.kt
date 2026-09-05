package com.ersingundem.larenor.wellbeing

import org.junit.Assert.*
import org.junit.Test

class WellbeingPermissionBrokerTest {
    @Test fun onlyExplicitForegroundCanCreateOneUseTicketAndNoRecordsAreCarried() {
        var now = 100L
        val broker = WellbeingPermissionBroker { now }
        val owner = Any()
        try { broker.begin(owner, setOf(WellbeingMetric.steps), false) { true }; fail("background allowed") }
        catch (_: IllegalArgumentException) { }
        val request = broker.begin(owner, setOf(WellbeingMetric.bodyMass), true) { true }
        assertNull(broker.take("forged"))
        assertSame(request, broker.take(request.token))
        assertNull(broker.take(request.token))
        assertSame(request, broker.active(request.token))
        broker.finish("forged")
        assertFalse(request.finished.isCompleted)
        broker.finish(request.token)
        assertTrue(request.finished.isCompleted)
        assertNull(broker.active(request.token))
        val expired = broker.begin(owner, setOf(WellbeingMetric.steps), true) { true }
        now += 5001
        assertNull(broker.take(expired.token))
        broker.disposeOwner(owner)
        assertTrue(expired.finished.isCompleted)
    }

    @Test fun duplicateRequestsAndDestroyedOwnerCannotLaunchPermissionFlow() {
        var alive = true
        val broker = WellbeingPermissionBroker { 10 }
        val owner = Any()
        val request = broker.begin(owner, setOf(WellbeingMetric.steps), true) { alive }
        try { broker.begin(owner, setOf(WellbeingMetric.bodyMass), true) { true }; fail("duplicate accepted") }
        catch (_: IllegalStateException) { }
        alive = false
        assertNull(broker.take(request.token))
        broker.disposeOwner(Any())
        assertFalse(request.finished.isCompleted)
        broker.disposeOwner(owner)
        assertTrue(request.finished.isCompleted)
    }
}
