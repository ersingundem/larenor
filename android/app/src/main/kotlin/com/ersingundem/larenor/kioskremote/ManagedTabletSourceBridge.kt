package com.ersingundem.larenor.kioskremote

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private class ManagedTabletSourceFailure(val code: String) : RuntimeException()

class ManagedTabletSourceBridge(
    activity: Activity,
    messenger: BinaryMessenger,
    private val host: ManagedTabletSnapshotHost = AndroidManagedTabletSnapshotHost(activity),
) : MethodChannel.MethodCallHandler {
    private data class Session(val id: String, val scope: String)

    private val channel = MethodChannel(messenger, "com.ersingundem.larenor/kiosk_remote_tablet_source")
    private var resumed = false
    private var disposed = false
    private var session: Session? = null

    init { channel.setMethodCallHandler(this) }

    @Synchronized
    fun setResumed(value: Boolean) {
        if (disposed) return
        resumed = value
        if (!value) session = null
    }

    @Synchronized
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("unavailable", "Tablet source unavailable", null)
            return
        }
        try {
            when (call.method) {
                "start" -> result.success(start(call.arguments))
                "snapshot" -> result.success(snapshot(call.arguments))
                "stop" -> { stop(call.arguments); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (failure: ManagedTabletSourceFailure) {
            result.error(failure.code, "Tablet source unavailable", null)
        } catch (_: RuntimeException) {
            result.error("unavailable", "Tablet source unavailable", null)
        }
    }

    private fun start(raw: Any?): Map<String, String> {
        val input = exactMap(raw, setOf("schemaVersion", "enabled", "sessionId", "scope"))
        if (input["schemaVersion"] != 1 || input["enabled"] !is Boolean) invalid()
        val id = validId(input["sessionId"])
        val scope = input["scope"] as? String ?: invalid()
        if (scope.length !in 1..128 || !scope.matches(Regex("^[A-Za-z0-9_.:-]+$"))) invalid()
        if (input["enabled"] != true) {
            session = null
            return mapOf("status" to "disabled")
        }
        if (!resumed) throw ManagedTabletSourceFailure("denied")
        session = Session(id, scope)
        return mapOf("status" to "active")
    }

    private fun snapshot(raw: Any?): Map<String, Any> {
        val input = exactMap(raw, setOf("sessionId"))
        val id = validId(input["sessionId"])
        val current = session
        if (!resumed || current == null || current.id != id) throw ManagedTabletSourceFailure("denied")
        return host.read(appForeground = true).toWire()
    }

    private fun stop(raw: Any?) {
        val input = exactMap(raw, setOf("sessionId"))
        val id = validId(input["sessionId"])
        if (session?.id == id) session = null
    }

    private fun exactMap(raw: Any?, keys: Set<String>): Map<*, *> {
        val input = raw as? Map<*, *> ?: invalid()
        if (input.keys != keys) invalid()
        return input
    }

    private fun validId(raw: Any?): String {
        val value = raw as? String ?: invalid()
        if (!value.matches(Regex("^[0-9a-f]{32}$"))) invalid()
        return value
    }

    private fun invalid(): Nothing = throw ManagedTabletSourceFailure("invalid")

    @Synchronized
    fun dispose() {
        disposed = true
        resumed = false
        session = null
        channel.setMethodCallHandler(null)
    }
}
