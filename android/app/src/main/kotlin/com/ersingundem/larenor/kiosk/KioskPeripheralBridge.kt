package com.ersingundem.larenor.kiosk

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Capability-only bridge. No scanner, speech, printing or web command handler exists. */
class KioskPeripheralBridge(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.ersingundem.larenor/kiosk_peripherals")
    private var disposed = false

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("unavailable", "Peripheral state unavailable", null); return }
        if (call.method != "capabilities") { result.notImplemented(); return }
        if (call.arguments != null) { result.error("invalid", "Peripheral state unavailable", null); return }
        result.success(unavailableCapabilities())
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
    }
}

/** An adapter is advertised only after a later verified native implementation. */
internal fun unavailableCapabilities(): Map<String, Any?> = mapOf(
    "schemaVersion" to 1,
    "inventoryRevision" to 1,
    "providers" to PeripheralKind.entries.map { kind ->
        mapOf(
            "providerId" to "${kind.name}.unavailable",
            "kind" to kind.name,
            "revision" to 1,
            "supported" to false,
            "enabledByUser" to false,
            "permission" to "unknown",
            "connected" to false,
            "requiresGms" to false,
            "maxPayloadBytes" to if (kind == PeripheralKind.tts || kind == PeripheralKind.print) 0 else 1,
        )
    },
)
