package com.ersingundem.larenor.rdp.packaged

import android.app.Application
import com.ersingundem.larenor.rdp.RdpKeyboardLayout
import com.ersingundem.larenor.rdp.RdpJniInput
import com.ersingundem.larenor.rdp.RdpJniSecurity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpPackagedPointerDisplayContractTest {
    private val security = RdpJniSecurity(
        minimumTlsProtocol = "TLSv1.2",
        nla = true,
        certificateFingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    )

    @Test
    fun connectionUriCarriesTheExactInitialSizeAndScaleSettings() {
        val uri = packagedConnectionUri(
            host = "fixture.invalid",
            port = 3389,
            username = "fixture",
            width = 2560,
            height = 1600,
            clipboard = false,
            keyboardLayout = RdpKeyboardLayout.TURKISH_Q,
            desktopScaleFactor = 225,
            deviceScaleFactor = 140,
        )

        assertEquals("2560x1600", uri.getQueryParameter("size"))
        assertEquals("225", uri.getQueryParameter("scale-desktop"))
        assertEquals("140", uri.getQueryParameter("scale-device"))
        assertEquals("+", uri.getQueryParameter("dynamic-resolution"))
    }

    @Test
    fun absolutePointerUsesTheAcknowledgedGeometryRatherThanTheNewestBitmap() {
        val events = absolutePointerWireEvents(
            RdpJniInput.AbsolutePointer(
                width = 1280,
                height = 800,
                x = .25,
                y = .75,
                buttons = 1,
            ),
            previousButtons = 0,
        )

        assertEquals(
            listOf(
                RdpPointerWireEvent(319, 599, 0x0800),
                RdpPointerWireEvent(319, 599, 0x9000),
            ),
            events,
        )
    }

    @Test
    fun relativePointerEmitsOnlyMoveAndExactChangedButtons() {
        assertEquals(
            listOf(
                RdpPointerWireEvent(-17, 23, 0x0800),
                RdpPointerWireEvent(0, 0, 0x1000),
                RdpPointerWireEvent(0, 0, 0xa000),
            ),
            relativePointerWireEvents(
                RdpJniInput.RelativePointer(-17, 23, 4),
                previousButtons = 1,
            ),
        )
        assertTrue(
            relativePointerWireEvents(
                RdpJniInput.RelativePointer(0, 0, 0),
                previousButtons = 0,
            ).isEmpty(),
        )
    }

    @Test
    fun verticalWheelUsesOneProtocolDetentInEitherDirection() {
        assertEquals(0x0278, verticalWheelFlags(120))
        assertEquals(0x0388, verticalWheelFlags(-120))
    }

    @Test
    fun peerCapsBeforeAuthenticationDispatchesTheInitialLayoutExactlyOnce() {
        val gate = RdpInitialDisplayGate(41)

        assertNull(gate.peerCaps(41))
        val dispatch = requireNotNull(gate.authenticated(security))
        assertNull(gate.peerCaps(41))
        assertNull(gate.authenticated(security))
        assertEquals(
            RdpInitialDisplayGate.Completion.Ready(security),
            gate.complete(dispatch, applied = true),
        )
        assertNull(gate.peerCaps(41))
    }

    @Test
    fun staleAndMissingCapsNeverReserveInitialLayoutIo() {
        val gate = RdpInitialDisplayGate(41)

        assertNull(gate.peerCaps(42))
        assertNull(gate.authenticated(security))
        assertNull(gate.peerCaps(42))
    }

    @Test
    fun failedInitialLayoutIsTerminalAndCannotReplay() {
        val gate = RdpInitialDisplayGate(41)
        assertNull(gate.authenticated(security))
        val dispatch = requireNotNull(gate.peerCaps(41))

        assertEquals(
            RdpInitialDisplayGate.Completion.Failed,
            gate.complete(dispatch, applied = false),
        )
        assertNull(gate.peerCaps(41))
        assertNull(gate.authenticated(security))
    }

    @Test
    fun retirementWhileLayoutIoIsPendingCannotPublishSecurity() {
        val gate = RdpInitialDisplayGate(41)
        assertNull(gate.authenticated(security))
        val dispatch = requireNotNull(gate.peerCaps(41))

        gate.retire()

        assertEquals(
            RdpInitialDisplayGate.Completion.Retired,
            gate.complete(dispatch, applied = true),
        )
        assertNull(gate.peerCaps(41))
    }
}
