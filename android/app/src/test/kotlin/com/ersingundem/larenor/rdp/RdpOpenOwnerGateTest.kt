package com.ersingundem.larenor.rdp

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Test

private fun cancellationBetweenAdvisoryCheckAndCommit(): Int {
    val gate = RdpOpenOwnerGate()
    val sink = Any()
    val owner = gate.capture(sink)
    val checked = CountDownLatch(1)
    val release = CountDownLatch(1)
    val published = AtomicReference<Any?>(null)
    val inputCalls = AtomicInteger(0)
    val committed = AtomicReference<Boolean?>(null)
    val publisher = Thread {
        check(gate.isCurrent(owner, sink))
        checked.countDown()
        check(release.await(2, TimeUnit.SECONDS))
        committed.set(gate.publishIfCurrent(owner, sink) {
            published.set(Any())
            inputCalls.incrementAndGet()
        })
    }
    publisher.start()
    check(checked.await(2, TimeUnit.SECONDS))
    gate.invalidate { published.set(null) }
    release.countDown()
    publisher.join(2_000)
    check(!publisher.isAlive)
    check(committed.get() == false)
    check(published.get() == null)
    check(inputCalls.get() == 0)
    return 5
}

private fun focusRestoreAndReplacementCannotRevive(): Int {
    val gate = RdpOpenOwnerGate()
    val firstSink = Any()
    val first = gate.capture(firstSink)
    gate.invalidate()
    check(!gate.publishIfCurrent(first, firstSink) { error("stale publish") })

    val successorSink = Any()
    val successor = gate.capture(successorSink)
    check(!gate.publishIfCurrent(first, successorSink) { error("old owner revived") })
    check(gate.publishIfCurrent(successor, successorSink) {})
    return 3
}

fun openOwnerGateChecks(): Int {
    val gate = RdpOpenOwnerGate()
    val firstSink = Any()
    val first = gate.capture(firstSink)
    check(gate.isCurrent(first, firstSink))

    // Models cancel/defocus while adapter.open is blocked. Focus restoration cannot revive it.
    gate.invalidate()
    check(!gate.isCurrent(first, firstSink))
    check(!gate.isCurrent(first, Any()))

    val successorSink = Any()
    val successor = gate.capture(successorSink)
    check(gate.isCurrent(successor, successorSink))
    check(!gate.isCurrent(first, successorSink))

    // A second retirement invalidates only the currently captured successor.
    gate.invalidate()
    check(!gate.isCurrent(successor, successorSink))
    return 6 + cancellationBetweenAdvisoryCheckAndCommit() +
        focusRestoreAndReplacementCannotRevive()
}

class RdpOpenOwnerGateJvmTest {
    @Test
    fun cancellationBetweenCheckAndPublicationHasZeroVisibilityOrInput() {
        check(cancellationBetweenAdvisoryCheckAndCommit() == 5)
    }

    @Test
    fun focusRestoreAndReplacementSinkCannotReviveCancelledOwner() {
        check(focusRestoreAndReplacementCannotRevive() == 3)
    }
}
