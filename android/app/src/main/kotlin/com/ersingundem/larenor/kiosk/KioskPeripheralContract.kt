package com.ersingundem.larenor.kiosk

import java.nio.charset.StandardCharsets
import java.util.ArrayDeque

enum class PeripheralKind { qr, nfc, ble, usb, tts, print }
enum class PeripheralPermission { notRequired, granted, denied, unknown }
enum class PeripheralAvailability { ready, disabled, unsupported, permissionDenied, permissionUnknown, disconnected, gmsUnavailable }
enum class PeripheralDisposition { reviewOnly }

class PeripheralFailure : RuntimeException("Peripheral input unavailable")

data class PeripheralAuthority(
    val deviceRevision: Int,
    val policyRevision: Int,
    val sessionEpoch: Int,
    val routeEpoch: Int,
    val lifecycleEpoch: Int,
) {
    val valid get() = listOf(deviceRevision, policyRevision, sessionEpoch, routeEpoch, lifecycleEpoch).all(::revision)
}

data class PeripheralCapability(
    val providerId: String,
    val kind: PeripheralKind,
    val revision: Int,
    val supported: Boolean,
    val enabledByUser: Boolean,
    val permission: PeripheralPermission,
    val connected: Boolean,
    val requiresGms: Boolean,
    val maxPayloadBytes: Int,
) {
    init {
        if (!Regex("[a-z][a-z0-9_.-]{2,63}").matches(providerId) || !revision(revision) ||
            if (kind.isInput) maxPayloadBytes !in 1..4096 else maxPayloadBytes != 0
        ) failPeripheral()
    }

    fun availability(gmsAvailable: Boolean) = when {
        !supported -> PeripheralAvailability.unsupported
        !enabledByUser -> PeripheralAvailability.disabled
        permission == PeripheralPermission.denied -> PeripheralAvailability.permissionDenied
        permission == PeripheralPermission.unknown -> PeripheralAvailability.permissionUnknown
        requiresGms && !gmsAvailable -> PeripheralAvailability.gmsUnavailable
        !connected -> PeripheralAvailability.disconnected
        else -> PeripheralAvailability.ready
    }
}

class KioskPeripheralInventory(
    val inventoryRevision: Int,
    val gmsAvailable: Boolean,
    providers: List<PeripheralCapability>,
) {
    val providers: List<PeripheralCapability> = java.util.Collections.unmodifiableList(ArrayList(providers))

    init {
        if (!revision(inventoryRevision) || this.providers.isEmpty() || this.providers.size > 24 ||
            this.providers.map { it.providerId }.toSet().size != this.providers.size ||
            !this.providers.map { it.kind }.toSet().containsAll(PeripheralKind.entries)
        ) failPeripheral()
    }

    fun provider(id: String): PeripheralCapability = providers.singleOrNull { it.providerId == id } ?: failPeripheral()
}

class PeripheralInput internal constructor(
    val eventId: String,
    val providerId: String,
    val kind: PeripheralKind,
    val capabilityRevision: Int,
    val sequence: Int,
    val capturedAtElapsedMs: Long,
    val payload: String,
) {
    val disposition = PeripheralDisposition.reviewOnly
    val canExecuteCommand = false
    val canInjectJavaScript = false
    override fun toString() = "PeripheralInput(redacted)"
}

class KioskPeripheralInputGate(
    private val maxAgeMs: Long = 15_000L,
    private val replayWindow: Int = 256,
) {
    private val seen = mutableSetOf<String>()
    private val seenOrder = ArrayDeque<String>()
    private val lastSequence = mutableMapOf<String, Int>()

    init {
        if (maxAgeMs !in 1..60_000 || replayWindow !in 16..1024) failPeripheral()
    }

    fun accept(
        raw: Any?,
        inventory: KioskPeripheralInventory,
        authority: PeripheralAuthority,
        current: Boolean,
        nowElapsedMs: Long,
    ): PeripheralInput {
        val keys = setOf(
            "schemaVersion", "eventId", "providerId", "kind", "capabilityRevision",
            "deviceRevision", "policyRevision", "sessionEpoch", "routeEpoch", "lifecycleEpoch",
            "sequence", "capturedAtElapsedMs", "payload",
        )
        val map = strictMap(raw, keys)
        if (!authority.valid || !current || integer(map["schemaVersion"]) != 1) failPeripheral()
        val id = map["eventId"] as? String ?: failPeripheral()
        val providerId = map["providerId"] as? String ?: failPeripheral()
        val kind = enumValue<PeripheralKind>(map["kind"])
        val capabilityRevision = integer(map["capabilityRevision"])
        val sequence = integer(map["sequence"])
        val capturedAt = longInteger(map["capturedAtElapsedMs"])
        val payload = map["payload"] as? String ?: failPeripheral()
        if (!Regex("[0-9a-f]{32}").matches(id) || id in seen || !kind.isInput ||
            !revision(capabilityRevision) || !revision(sequence) || capturedAt < 0 ||
            capturedAt > nowElapsedMs || nowElapsedMs - capturedAt > maxAgeMs ||
            payload.isEmpty() || payload.contains('\u0000') ||
            integer(map["deviceRevision"]) != authority.deviceRevision ||
            integer(map["policyRevision"]) != authority.policyRevision ||
            integer(map["sessionEpoch"]) != authority.sessionEpoch ||
            integer(map["routeEpoch"]) != authority.routeEpoch ||
            integer(map["lifecycleEpoch"]) != authority.lifecycleEpoch
        ) failPeripheral()
        val capability = inventory.provider(providerId)
        if (capability.kind != kind || capability.revision != capabilityRevision ||
            capability.availability(inventory.gmsAvailable) != PeripheralAvailability.ready ||
            payload.toByteArray(StandardCharsets.UTF_8).size > capability.maxPayloadBytes ||
            sequence <= (lastSequence[providerId] ?: 0)
        ) failPeripheral()
        seen += id
        seenOrder.addLast(id)
        if (seenOrder.size > replayWindow) seen -= seenOrder.removeFirst()
        lastSequence[providerId] = sequence
        return PeripheralInput(id, providerId, kind, capabilityRevision, sequence, capturedAt, payload)
    }
}

private val PeripheralKind.isInput get() = this in setOf(PeripheralKind.qr, PeripheralKind.nfc, PeripheralKind.ble, PeripheralKind.usb)
private fun revision(value: Int) = value in 1..Int.MAX_VALUE
private fun failPeripheral(): Nothing = throw PeripheralFailure()

private fun strictMap(raw: Any?, keys: Set<String>): Map<*, *> {
    val map = raw as? Map<*, *> ?: failPeripheral()
    if (map.size != keys.size || map.keys.any { it !is String || it !in keys }) failPeripheral()
    return map
}

private fun integer(raw: Any?): Int {
    return when (raw) {
        is Int -> raw
        is Long -> raw.takeIf { it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }?.toInt() ?: failPeripheral()
        else -> failPeripheral()
    }
}

private fun longInteger(raw: Any?): Long {
    return when (raw) {
        is Int -> raw.toLong()
        is Long -> raw
        else -> failPeripheral()
    }
}

private inline fun <reified T : Enum<T>> enumValue(raw: Any?): T =
    enumValues<T>().firstOrNull { it.name == raw } ?: failPeripheral()
