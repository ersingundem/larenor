package com.ersingundem.larenor.rdp.packaged

import android.app.Application
import com.ersingundem.larenor.rdp.RdpKeyboardLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpPackagedKeyboardContractTest {
    @Test
    fun uriConsumesExactKeyboardLayoutAndEnablesNegotiatedUnicodeInput() {
        val automatic = packagedConnectionUri("fixture.invalid", 3389, "fixture", 1280, 800, false, RdpKeyboardLayout.AUTOMATIC)
        val turkish = packagedConnectionUri("fixture.invalid", 3389, "fixture", 1280, 800, false, RdpKeyboardLayout.TURKISH_Q)
        val us = packagedConnectionUri("fixture.invalid", 3389, "fixture", 1280, 800, false, RdpKeyboardLayout.US)

        assertEquals("unicode:on", automatic.getQueryParameter("kbd"))
        assertEquals("layout:1055,unicode:on", turkish.getQueryParameter("kbd"))
        assertEquals("layout:1033,unicode:on", us.getQueryParameter("kbd"))
    }

    @Test
    fun usbKeyboardMappingCoversShortcutsPunctuationNavigationAndFunctionKeys() {
        assertEquals(0x41, usbKeyboardVirtualKey(0x00070004))
        assertEquals(0x31, usbKeyboardVirtualKey(0x0007001e))
        assertEquals(0xBF, usbKeyboardVirtualKey(0x00070038))
        assertEquals(0x70, usbKeyboardVirtualKey(0x0007003a))
        assertEquals(0x2E, usbKeyboardVirtualKey(0x0007004c))
        assertEquals(0xA2, usbKeyboardVirtualKey(0x000700e0))
        assertEquals(0xA5, usbKeyboardVirtualKey(0x000700e6))
        assertNull(usbKeyboardVirtualKey(0x000c00e9))
        assertNull(usbKeyboardVirtualKey(0x00070066))
    }

    @Test
    fun strictUtf16UnitsPreserveTurkishAndSupplementaryText() {
        assertEquals(
            listOf(0x130, 0x73, 0x74, 0x61, 0x6e, 0x62, 0x75, 0x6c, 0xd83d, 0xde00),
            strictUtf16Units("İstanbul😀").toList(),
        )
        assertTrue(strictUtf16Units("\u0000").isEmpty())
        assertTrue(strictUtf16Units("\ud800").isEmpty())
    }
}
