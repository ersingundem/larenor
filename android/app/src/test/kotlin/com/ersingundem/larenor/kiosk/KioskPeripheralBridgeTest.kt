package com.ersingundem.larenor.kiosk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KioskPeripheralBridgeTest {
    @Test fun noProviderClaimsHardwareOrCommandCapability() {
        val raw = unavailableCapabilities()
        assertEquals(1, raw["schemaVersion"])
        val providers = raw["providers"] as List<*>
        assertEquals(6, providers.size)
        assertEquals(PeripheralKind.entries.map { it.name }.toSet(),
            providers.map { (it as Map<*, *>)["kind"] }.toSet())
        providers.forEach {
            val provider = it as Map<*, *>
            assertEquals(false, provider["supported"])
            assertEquals(false, provider["enabledByUser"])
            assertEquals("unknown", provider["permission"])
            assertEquals(false, provider["connected"])
            assertFalse(provider.containsKey("execute"))
            assertFalse(provider.containsKey("javascript"))
            assertTrue((provider["providerId"] as String).endsWith(".unavailable"))
        }
    }
}
