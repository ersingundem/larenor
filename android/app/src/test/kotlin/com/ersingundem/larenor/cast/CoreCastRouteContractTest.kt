package com.ersingundem.larenor.cast

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreCastRouteContractTest {
    @Test fun strictSnapshotAcceptsOnlySanitizedCastDeviceIdentity() {
        val snapshot = CoreCastRouteSnapshot.parse(mapOf(
            "revision" to 8L,
            "routes" to listOf(route()),
        ))
        assertEquals("01234567-89ab-cdef-0123-456789abcdef", snapshot.routes.single().id)
        assertEquals("Living TV", snapshot.routes.single().name)
        assertTrue(snapshot.routes.single().available)
        assertFalse(snapshot.toMap().toString().contains("192.168"))

        for (extra in listOf("host", "endpoint", "token", "provider")) {
            assertThrows(CoreCastRouteRejected::class.java) {
                CoreCastRouteSnapshot.parse(mapOf(
                    "revision" to 8L,
                    "routes" to listOf(route() + (extra to "private")),
                ))
            }
        }
    }

    @Test fun duplicatesInvalidIdsOversizeAndRevisionRollbackFailClosed() {
        for (routes in listOf(
            listOf(route(), route()),
            listOf(route(id = "not-a-cast-uuid")),
            List(65) { route(id = "00000000-0000-0000-0000-${it.toString().padStart(12, '0')}") },
        )) {
            assertThrows(CoreCastRouteRejected::class.java) {
                CoreCastRouteSnapshot.parse(mapOf("revision" to 8L, "routes" to routes))
            }
        }
        val gate = CoreCastRouteGate()
        gate.publish(CoreCastRouteSnapshot.parse(mapOf("revision" to 8L, "routes" to listOf(route()))))
        assertThrows(CoreCastRouteRejected::class.java) {
            gate.publish(CoreCastRouteSnapshot.parse(mapOf("revision" to 8L, "routes" to emptyList<Any>())))
        }
        assertTrue(gate.snapshot().routes.isEmpty())
    }

    private fun route(id: String = "01234567-89ab-cdef-0123-456789abcdef") = mapOf(
        "id" to id,
        "name" to "Living TV",
        "kind" to "device",
        "available" to true,
        "connectionState" to "disconnected",
        "volumeLevel" to null,
    )
}
