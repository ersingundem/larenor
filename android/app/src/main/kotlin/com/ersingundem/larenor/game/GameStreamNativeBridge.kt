package com.ersingundem.larenor.game

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class GameStreamNativeBridge(
    messenger: BinaryMessenger,
    engine: GameStreamNativeEngine? = null,
) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, CHANNEL)
    private val adapter = GameStreamNativeAdapter(engine)
    private var resumed = false
    private var focused = true
    private var disposed = false

    init {
        methods.setMethodCallHandler(this)
    }

    fun setResumed(value: Boolean) {
        if (disposed) return
        resumed = value
        if (!value) retireForBoundary()
    }

    fun setWindowFocused(value: Boolean) {
        if (disposed) return
        focused = value
        if (!value) retireForBoundary()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return error(result, "engineUnavailable")
        try {
            when (call.method) {
                "capabilities" -> {
                    if (call.arguments != null) gameStreamFail("invalidRequest")
                    result.success(adapter.capabilities().toChannel())
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
    }
}
