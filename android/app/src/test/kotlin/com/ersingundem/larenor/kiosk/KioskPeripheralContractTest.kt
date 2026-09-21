package com.ersingundem.larenor.kiosk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test

class KioskPeripheralContractTest {
    private val authority = PeripheralAuthority(7, 11, 13, 17, 19)

    private fun capabilities() = KioskPeripheralInventory(
        inventoryRevision = 5,
        gmsAvailable = false,
        providers = listOf(
            PeripheralCapability("qr.local_camera", PeripheralKind.qr, 3, true, true, PeripheralPermission.granted, true, false, 512),
            PeripheralCapability("nfc.android", PeripheralKind.nfc, 3, true, true, PeripheralPermission.denied, true, false, 512),
            PeripheralCapability("ble.local", PeripheralKind.ble, 3, true, true, PeripheralPermission.granted, true, false, 512),
            PeripheralCapability("ble.play_services", PeripheralKind.ble, 3, true, true, PeripheralPermission.granted, true, true, 512),
            PeripheralCapability("usb.hid", PeripheralKind.usb, 3, true, true, PeripheralPermission.granted, false, false, 512),
            PeripheralCapability("tts.android", PeripheralKind.tts, 3, true, true, PeripheralPermission.notRequired, true, false, 0),
            PeripheralCapability("print.android", PeripheralKind.print, 3, true, true, PeripheralPermission.notRequired, true, false, 0),
        ),
    )

    private fun event(id: String = "0123456789abcdef0123456789abcdef", sequence: Int = 1) = mapOf(
        "schemaVersion" to 1,
        "eventId" to id,
        "providerId" to "qr.local_camera",
        "kind" to "qr",
        "capabilityRevision" to 3,
        "deviceRevision" to 7,
        "policyRevision" to 11,
        "sessionEpoch" to 13,
        "routeEpoch" to 17,
        "lifecycleEpoch" to 19,
        "sequence" to sequence,
        "capturedAtElapsedMs" to 49_000L,
        "payload" to "javascript:alert(1)",
    )

    private fun fails(action: () -> Unit) {
        try { action(); fail("expected fail-closed rejection") } catch (_: PeripheralFailure) {}
    }

    @Test fun inventorySeparatesOptInPermissionConnectionAndGms() {
        val inventory = capabilities()
        assertEquals(PeripheralAvailability.ready, inventory.provider("qr.local_camera").availability(false))
        assertEquals(PeripheralAvailability.permissionDenied, inventory.provider("nfc.android").availability(false))
        assertEquals(PeripheralAvailability.gmsUnavailable, inventory.provider("ble.play_services").availability(false))
        assertEquals(PeripheralAvailability.disconnected, inventory.provider("usb.hid").availability(false))
        assertEquals(6, inventory.providers.map { it.kind }.toSet().size)
        assertEquals(
            PeripheralAvailability.disabled,
            inventory.provider("qr.local_camera").copyForTest(enabledByUser = false).availability(false),
        )
    }

    @Test fun inputIsBoundedReviewOnlyAndNeverExecutes() {
        val accepted = KioskPeripheralInputGate().accept(event(), capabilities(), authority, true, 50_000L)
        assertEquals("javascript:alert(1)", accepted.payload)
        assertEquals(PeripheralDisposition.reviewOnly, accepted.disposition)
        assertFalse(accepted.canExecuteCommand)
        assertFalse(accepted.canInjectJavaScript)

        fails { KioskPeripheralInputGate().accept(event() + ("providerId" to "nfc.android") + ("kind" to "nfc"), capabilities(), authority, true, 50_000L) }
        fails { KioskPeripheralInputGate().accept(event() + ("providerId" to "tts.android") + ("kind" to "tts"), capabilities(), authority, true, 50_000L) }
        fails { KioskPeripheralInputGate().accept(event() + ("payload" to "x".repeat(513)), capabilities(), authority, true, 50_000L) }
        fails { KioskPeripheralInputGate().accept(event() + ("sequence" to 1.0), capabilities(), authority, true, 50_000L) }
    }

    @Test fun duplicateReplayStaleAndRevokedEventsAreRejected() {
        val gate = KioskPeripheralInputGate()
        gate.accept(event(sequence = 9), capabilities(), authority, true, 50_000L)
        fails { gate.accept(event(sequence = 9), capabilities(), authority, true, 50_000L) }
        fails { gate.accept(event("1123456789abcdef0123456789abcdef", 8), capabilities(), authority, true, 50_000L) }
        fails { gate.accept(event("2123456789abcdef0123456789abcdef", 10) + ("capturedAtElapsedMs" to 1_000L), capabilities(), authority, true, 50_000L) }
        fails { gate.accept(event("3123456789abcdef0123456789abcdef", 10), capabilities(), authority, false, 50_000L) }
    }

    private fun PeripheralCapability.copyForTest(enabledByUser: Boolean) = PeripheralCapability(
        providerId, kind, revision, supported, enabledByUser, permission, connected, requiresGms, maxPayloadBytes,
    )
}
