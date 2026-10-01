package com.ersingundem.larenor.rdp

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RdpPackagedLifecycleDiagnosticTest {
    @Test
    fun bodyFailureMarkerIsClosedStageAndExactThrowableWithoutPrivateMessage() {
        val secret = "private-provider-and-credential-detail"
        val failure = try {
            diagnoseOwnedTestBody { entered ->
                entered("providerInspection")
                throw IllegalStateException(secret)
            }
            fail("body failure must be classified")
            error("unreachable")
        } catch (caught: RdpOwnedTestBodyFailure) {
            caught
        }

        assertEquals("providerInspection", failure.lifecycleStage)
        assertEquals("java.lang.IllegalStateException", failure.throwableClass)
        assertEquals(
            "stage=providerInspection;throwable=java.lang.IllegalStateException",
            failure.message,
        )
        assertFalse(failure.stackTraceToString().contains(secret))

        class PrivateFailure : RuntimeException(secret)
        val unclassified = try {
            diagnoseOwnedTestBody { entered ->
                entered("runtimeValidation")
                throw PrivateFailure()
            }
            fail("body failure must be classified")
            error("unreachable")
        } catch (caught: RdpOwnedTestBodyFailure) {
            caught
        }
        assertEquals("runtimeValidation", unclassified.lifecycleStage)
        assertEquals("unclassified", unclassified.throwableClass)
        assertFalse(unclassified.stackTraceToString().contains(secret))
        assertFalse(unclassified.stackTraceToString().contains(PrivateFailure::class.java.name))
    }

    @Test
    fun bodyGuardPreservesTypedStageFailuresInterruptAndFatalThrowables() {
        val typed = initialFrameTerminalFailure(
            RdpJniPhase.FAILED,
            "connectionFailed",
            AssertionError("private"),
        )
        val observedTyped = try {
            diagnoseOwnedTestBody { throw typed }
            fail("typed failure must escape")
            error("unreachable")
        } catch (caught: AssertionError) {
            caught
        }
        assertSame(typed, observedTyped)

        Thread.interrupted()
        try {
            val interrupted = try {
                diagnoseOwnedTestBody { entered ->
                    entered("firstSecurityWait")
                    throw InterruptedException("private")
                }
                fail("interrupt must be classified")
                error("unreachable")
            } catch (caught: RdpOwnedTestBodyFailure) {
                caught
            }
            assertEquals("java.lang.InterruptedException", interrupted.throwableClass)
            assertTrue(Thread.currentThread().isInterrupted)
        } finally {
            Thread.interrupted()
        }

        val fatal = object : VirtualMachineError("private") {}
        val observedFatal = try {
            diagnoseOwnedTestBody { throw fatal }
            fail("fatal error must escape")
            error("unreachable")
        } catch (caught: VirtualMachineError) {
            caught
        }
        assertSame(fatal, observedFatal)

        val death = ThreadDeath()
        val observedDeath = try {
            diagnoseOwnedTestBody { throw death }
            fail("thread death must escape")
            error("unreachable")
        } catch (caught: ThreadDeath) {
            caught
        }
        assertSame(death, observedDeath)
    }

    @Test
    fun terminalFailureClassificationUsesOnlyFixedPhaseAndCodeTuples() {
        val cause = AssertionError("owned")
        val cases = listOf(
            Triple(RdpJniPhase.FAILED, "connectionFailed", "RdpOwnedInitialFrameConnectionFailed"),
            Triple(RdpJniPhase.FAILED, "frameBackpressure", "RdpOwnedInitialFrameBackpressureFailure"),
            Triple(RdpJniPhase.FAILED, "framebufferUnavailable", "RdpOwnedInitialFramebufferUnavailable"),
            Triple(RdpJniPhase.FAILED, "staleSession", "RdpOwnedInitialFrameStaleSession"),
            Triple(RdpJniPhase.CANCELLED, null, "RdpOwnedInitialFrameCancelled"),
        )
        cases.forEach { (phase, code, expected) ->
            assertEquals(
                expected,
                initialFrameTerminalFailure(phase, code, cause)::class.java.simpleName,
            )
        }
        assertEquals(
            "RdpOwnedInitialFrameTerminalFailure",
            initialFrameTerminalFailure(
                RdpJniPhase.CANCELLED,
                "connectionFailed",
                cause,
            )::class.java.simpleName,
        )
        assertEquals(
            "RdpOwnedInitialFrameTerminalFailure",
            initialFrameTerminalFailure(RdpJniPhase.ACTIVE, null, cause)::class.java.simpleName,
        )
    }

    @Test
    fun atomicMarkerRetainsLatestFixedStageAndRemovesOnlyItsOwnedFile() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val nonce = "e".repeat(64)
        val marker = File(context.filesDir, "f62-owned-stage-$nonce")
        val unrelated = File(context.filesDir, "f62-owned-stage-unrelated")
        marker.delete()
        unrelated.writeText("keep")

        try {
            val diagnostic = OwnedLifecycleDiagnostic(
                AtomicLifecycleStorage(context, nonce),
            )
            diagnostic.enter("testInitialization")
            assertEquals("testInitialization", marker.readText())

            diagnostic.enter("initialFrameWait")
            assertEquals("initialFrameWait", marker.readText())

            diagnostic.remove()
            assertFalse(marker.exists())
            assertEquals("keep", unrelated.readText())

            val secondary = OwnedLifecycleDiagnostic(object : LifecycleStorage {
                override fun write(stage: String) {
                    throw java.io.IOException("owned diagnostic unavailable")
                }

                override fun remove() {
                    throw SecurityException("owned diagnostic unavailable")
                }
            })
            secondary.enter("providerInspection")
            secondary.remove()
        } finally {
            marker.delete()
            unrelated.delete()
        }
    }
}
