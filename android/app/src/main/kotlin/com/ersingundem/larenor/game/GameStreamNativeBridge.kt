package com.ersingundem.larenor.game

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.function.Consumer

class GameStreamNativeBridge(
    messenger: BinaryMessenger,
    engine: GameStreamNativeEngine? = null,
    activity: Activity? = null,
    private val embeddedHost: GameStreamEmbeddedHost? = activity?.let(MoonlightEmbeddedHostLoader::load),
) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, CHANNEL)
    private val adapter = GameStreamNativeAdapter(engine)
    private var resumed = false
    private var focused = true
    private var disposed = false
    private val v2Mode = activity != null || embeddedHost != null

    init {
        methods.setMethodCallHandler(this)
    }

    fun setResumed(value: Boolean) {
        if (disposed) return
        resumed = value
        embeddedHost?.setResumed(value)
        if (!value && !v2Mode) retireForBoundary()
    }

    fun setWindowFocused(value: Boolean) {
        if (disposed) return
        focused = value
        embeddedHost?.setWindowFocused(value)
        if (!value && !v2Mode) retireForBoundary()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (v2Mode) return embeddedCall(call, result)
        if (disposed) return error(result, "engineUnavailable")
        try {
            when (call.method) {
                "capabilities" -> {
                    if (call.arguments != null) gameStreamFail("invalidRequest")
                    result.success(adapter.capabilities().toChannel())
                }
                "openProvider" -> {
                    requireForeground()
                    if (call.arguments != null) gameStreamFail("invalidRequest")
                    result.success(adapter.openProvider().toChannel())
                }
                "bind" -> {
                    requireForeground()
                    adapter.bind(GameStreamNativeBinding.parse(call.arguments))
                    result.success(null)
                }
                "execute" -> execute(call.arguments, result)
                "retire" -> {
                    val value = strictMap(call.arguments, setOf("sessionId", "epoch"))
                    adapter.retire(
                        gameStreamIdentity(value["sessionId"]),
                        gameStreamRevision(value["epoch"]),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (failure: GameStreamNativeFailure) {
            error(result, failure.code)
        } catch (_: Exception) {
            error(result, "unknownEffect")
        }
    }

    private fun embeddedCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed || embeddedHost == null) return embeddedError(result, "engine_unavailable")
        // Stop/reconcile/retire remain usable for the exact private Game lease.
        // The native host checks their session/authority and never grants a new transfer.
        if (call.method in FOREGROUND_V2_METHODS && !foreground()) {
            return embeddedError(result, "foreground_required")
        }
        val completed = AtomicBoolean(false)
        val success = Consumer<Any?> { value ->
            if (completed.compareAndSet(false, true)) main.post {
                if (disposed) embeddedError(result, "authority_changed") else result.success(value)
            }
        }
        val error = Consumer<String> { code ->
            if (completed.compareAndSet(false, true)) main.post { embeddedError(result, code) }
        }
        try {
            if (!embeddedHost.handle(call.method, call.arguments, success, error)) {
                error.accept("engine_unavailable")
            }
        } catch (_: Exception) {
            error.accept("unknown_effect")
        }
    }

    private fun embeddedError(result: MethodChannel.Result, code: String) {
        val safe = if (code in V2_ERROR_CODES) code else "unknown_effect"
        result.error(safe, null, mapOf("schemaVersion" to 2, "code" to safe))
    }

    private fun execute(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        val value = strictMap(raw, setOf("sessionId", "epoch", "command"))
        val sessionId = gameStreamIdentity(value["sessionId"])
        val epoch = gameStreamRevision(value["epoch"])
        val command = GameStreamNativeCommand.parse(value["command"])
        adapter.execute(sessionId, epoch, command) { outcome ->
            main.post {
                if (!foreground()) {
                    retireForBoundary()
                    error(result, "staleSession")
                } else when (outcome) {
                    is GameStreamNativeOutcome.Success -> result.success(outcome.receipt.toChannel())
                    is GameStreamNativeOutcome.Failure -> error(result, outcome.failure.code)
                }
            }
        }
    }

    private fun requireForeground() {
        if (!foreground()) gameStreamFail("foregroundRequired")
    }

    private fun foreground() = resumed && focused && !disposed

    private fun retireForBoundary() {
        try {
            adapter.retire()
        } catch (_: Exception) {
            // Retirement is best effort after local authority is already revoked.
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        retireForBoundary()
        embeddedHost?.dispose()
        methods.setMethodCallHandler(null)
    }

    private fun error(result: MethodChannel.Result, code: String) {
        val failure = try {
            GameStreamNativeFailure(code)
        } catch (_: Exception) {
            GameStreamNativeFailure("unknownEffect")
        }
        result.error(failure.code, null, failure.publicDetails())
    }

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/game-stream-native"
        private val FOREGROUND_V2_METHODS = setOf(
            "beginPairingV2", "pairHostV2", "commitRegistrationV2", "resolveHostBindingV2",
            "resolveBindingV2", "configureStreamPolicyV2", "readCatalogV2", "sessionCapabilitiesV2",
            "bindSessionV2", "revokePairingV2",
        )
        private val V2_ERROR_CODES = setOf(
            "authority_changed", "busy", "cancelled", "engine_unavailable", "foreground_required",
            "invalid_account_id", "invalid_authority_id", "invalid_candidate", "invalid_candidate_revision",
            "invalid_core_id", "invalid_family_id", "invalid_home_id", "invalid_pairing_revision",
            "invalid_request_id", "invalid_revision", "invalid_session_id", "invalid_timeout",
            "invalid_receipt", "pin_required", "provider_unavailable", "quarantined", "stale_candidate", "stale_pairing",
            "unknown_effect", "unsupported",
        )
    }
}
