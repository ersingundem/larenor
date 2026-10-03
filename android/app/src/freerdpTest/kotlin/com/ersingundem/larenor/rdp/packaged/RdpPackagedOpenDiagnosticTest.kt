package com.ersingundem.larenor.rdp.packaged

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpPackagedOpenDiagnosticTest {
    @Test
    fun activeAndSuccessfulOperationsAreNeverConsumable() {
        val slot = RdpPackagedOpenDiagnosticSlot()
        val operation = slot.begin(FIRST_REQUEST)

        operation.connectionInfoParsed()
        operation.connectAccepted()
        operation.certificateAccepted()
        operation.authenticatedConnectionSucceeded()
        operation.displayCapsObserved()
        operation.initialLayoutAccepted()
        operation.securityPublished()

        assertNull(slot.consumeFailed(FIRST_REQUEST))
        operation.succeeded()
        assertNull(slot.consumeFailed(FIRST_REQUEST))
    }

    @Test
    fun successfulStartClearsAConcurrentPostAcceptanceRetirement() {
        val slot = RdpPackagedOpenDiagnosticSlot()
        val operation = slot.begin(FIRST_REQUEST)
        operation.connectionInfoParsed()
        operation.connectAccepted()
        operation.certificateAccepted()
        operation.authenticatedConnectionSucceeded()
        operation.initialLayoutAccepted()
        operation.securityPublished()

        // A close may race immediately after start computes acceptance. Once
        // success linearizes, it is session retirement, not a failed open.
        operation.retired()
        operation.succeeded()

        assertNull(slot.consumeFailed(FIRST_REQUEST))
    }

    @Test
    fun exactFailureSnapshotIsSingleUseAndFirstTerminalWins() {
        val slot = RdpPackagedOpenDiagnosticSlot()
        val operation = slot.begin(FIRST_REQUEST)
        operation.connectionInfoParsed()
        operation.connectAccepted()
        operation.certificateAccepted()
        operation.connectionFailureCallback()

        operation.authenticatedConnectionSucceeded()
        operation.displayCapsObserved()
        operation.initialLayoutAccepted()
        operation.securityPublished()
        operation.timeout()
        operation.retired()

        assertNull(slot.consumeFailed(SECOND_REQUEST))
        val snapshot = requireNotNull(slot.consumeFailed(FIRST_REQUEST))
        assertEquals(RdpPackagedOpenTerminalKind.CONNECTION_FAILURE_CALLBACK, snapshot.terminal)
        assertTrue(snapshot.connectionInfoParsed)
        assertTrue(snapshot.connectAccepted)
        assertTrue(snapshot.certificateAccepted)
        assertFalse(snapshot.authenticatedConnectionSucceeded)
        assertFalse(snapshot.displayCapsObserved)
        assertFalse(snapshot.initialLayoutAccepted)
        assertFalse(snapshot.securityPublished)
        assertFalse(snapshot.timeout)
        assertFalse(snapshot.toString().contains(FIRST_REQUEST))
        assertNull(slot.consumeFailed(FIRST_REQUEST))
    }

    @Test
    fun successorClearsOldFailureAndLateOldCallbacksCannotOverwriteIt() {
        val slot = RdpPackagedOpenDiagnosticSlot()
        val old = slot.begin(FIRST_REQUEST)
        old.connectionInfoParsed()
        old.connectionFailureCallback()

        val successor = slot.begin(SECOND_REQUEST)
        old.authenticatedConnectionSucceeded()
        old.timeout()
        successor.connectionInfoParsed()
        successor.connectAccepted()
        successor.timeout()

        assertNull(slot.consumeFailed(FIRST_REQUEST))
        val snapshot = requireNotNull(slot.consumeFailed(SECOND_REQUEST))
        assertEquals(RdpPackagedOpenTerminalKind.TIMEOUT, snapshot.terminal)
        assertTrue(snapshot.timeout)
        assertTrue(snapshot.connectionInfoParsed)
        assertTrue(snapshot.connectAccepted)
        assertFalse(snapshot.certificateAccepted)
    }

    @Test
    fun sameRequestIdSuccessorIsSelectedByOperationIdentity() {
        val slot = RdpPackagedOpenDiagnosticSlot()
        val old = slot.begin(FIRST_REQUEST)

        val successor = slot.begin(FIRST_REQUEST)
        old.connectionInfoParsed()
        old.connectAccepted()
        old.certificateAccepted()
        old.connectionFailureCallback()
        old.timeout()
        old.displayCapsObserved()
        successor.connectionInfoParsed()
        successor.connectAccepted()
        successor.disconnectedCallback()

        val snapshot = requireNotNull(slot.consumeFailed(FIRST_REQUEST))
        assertEquals(RdpPackagedOpenTerminalKind.DISCONNECTED_CALLBACK, snapshot.terminal)
        assertTrue(snapshot.connectionInfoParsed)
        assertTrue(snapshot.connectAccepted)
        assertFalse(snapshot.certificateAccepted)
        assertFalse(snapshot.displayCapsObserved)
        assertFalse(snapshot.timeout)
    }

    @Test
    fun displayAndAuthenticationCallbacksMayArriveInEitherOrder() {
        val slot = RdpPackagedOpenDiagnosticSlot()
        val displayFirst = slot.begin(FIRST_REQUEST)
        displayFirst.connectionInfoParsed()
        displayFirst.connectAccepted()
        displayFirst.displayCapsObserved()
        displayFirst.certificateAccepted()
        displayFirst.authenticatedConnectionSucceeded()
        displayFirst.initialLayoutAccepted()
        displayFirst.localSetupRejected()

        val first = requireNotNull(slot.consumeFailed(FIRST_REQUEST))
        assertTrue(first.displayCapsObserved)
        assertTrue(first.authenticatedConnectionSucceeded)
        assertTrue(first.initialLayoutAccepted)
        assertEquals(RdpPackagedOpenTerminalKind.LOCAL_SETUP_REJECTED, first.terminal)

        val authenticationFirst = slot.begin(SECOND_REQUEST)
        authenticationFirst.connectionInfoParsed()
        authenticationFirst.connectAccepted()
        authenticationFirst.certificateAccepted()
        authenticationFirst.authenticatedConnectionSucceeded()
        authenticationFirst.displayCapsObserved()
        authenticationFirst.initialLayoutAccepted()
        authenticationFirst.securityPublished()
        authenticationFirst.disconnectedCallback()

        val second = requireNotNull(slot.consumeFailed(SECOND_REQUEST))
        assertTrue(second.authenticatedConnectionSucceeded)
        assertTrue(second.displayCapsObserved)
        assertTrue(second.securityPublished)
        assertEquals(RdpPackagedOpenTerminalKind.DISCONNECTED_CALLBACK, second.terminal)
    }

    @Test
    fun localDisplayOrAudioFailureCannotBeRelabeledAsConnectionCallback() {
        val slot = RdpPackagedOpenDiagnosticSlot()
        val operation = slot.begin(FIRST_REQUEST)
        operation.connectionInfoParsed()
        operation.connectAccepted()
        operation.certificateAccepted()
        operation.authenticatedConnectionSucceeded()
        operation.displayCapsObserved()
        operation.localSetupRejected()

        // The common terminal action invokes the same failed() method used by
        // the JNI registry, but first-terminal semantics retain the local fact.
        operation.connectionFailureCallback()
        operation.disconnectedCallback()
        operation.retired()

        val snapshot = requireNotNull(slot.consumeFailed(FIRST_REQUEST))
        assertEquals(RdpPackagedOpenTerminalKind.LOCAL_SETUP_REJECTED, snapshot.terminal)
        assertTrue(snapshot.authenticatedConnectionSucceeded)
        assertTrue(snapshot.displayCapsObserved)
        assertFalse(snapshot.timeout)
    }

    @Test
    fun candidateCreationAndRetirementRemainDistinctFiniteOutcomes() {
        val slot = RdpPackagedOpenDiagnosticSlot()
        val creation = slot.begin(FIRST_REQUEST)
        creation.candidateCreateFailure()
        assertEquals(
            RdpPackagedOpenTerminalKind.CANDIDATE_CREATE_FAILURE,
            requireNotNull(slot.consumeFailed(FIRST_REQUEST)).terminal,
        )

        val retired = slot.begin(SECOND_REQUEST)
        retired.connectionInfoParsed()
        retired.retired()
        val snapshot = requireNotNull(slot.consumeFailed(SECOND_REQUEST))
        assertEquals(RdpPackagedOpenTerminalKind.RETIRED, snapshot.terminal)
        assertFalse(snapshot.timeout)
    }

    @Test
    fun terminalWireValuesAreClosedAndNoneIsNeverPublished() {
        assertEquals(
            setOf(
                "none",
                "candidateCreateFailure",
                "localSetupRejected",
                "connectionFailureCallback",
                "disconnectedCallback",
                "retired",
                "timeout",
            ),
            RdpPackagedOpenTerminalKind.entries.map { it.wireValue }.toSet(),
        )

        val slot = RdpPackagedOpenDiagnosticSlot()
        slot.begin(FIRST_REQUEST)
        assertNull(slot.consumeFailed(FIRST_REQUEST))
    }

    companion object {
        private const val FIRST_REQUEST = "62726270-0000-4000-8000-000000000001"
        private const val SECOND_REQUEST = "62726270-0000-4000-8000-000000000002"
    }
}
