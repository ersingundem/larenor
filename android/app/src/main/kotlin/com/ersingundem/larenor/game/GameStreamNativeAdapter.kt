package com.ersingundem.larenor.game

sealed interface GameStreamNativeOutcome {
    data class Success(val receipt: GameStreamEngineReceipt) : GameStreamNativeOutcome
    data class Failure(val failure: GameStreamNativeFailure) : GameStreamNativeOutcome
}

/**
 * Owns the bounded Android-side command lease. This class intentionally does not
 * implement video, audio, input, pairing, or credential storage. A packaged
 * engine must prove an exact readback through [GameStreamNativeEngine].
 */
class GameStreamNativeAdapter(
    private val engine: GameStreamNativeEngine?,
) {
    private data class Operation(
        val fingerprint: String,
        val generation: Long,
        val callbacks: MutableList<(GameStreamNativeOutcome) -> Unit>,
        var terminal: GameStreamNativeOutcome? = null,
    )

    private var binding: GameStreamNativeBinding? = null
    private var generation = 0L
    private val operations = linkedMapOf<GameStreamNativeIntent, Operation>()

    @Synchronized
    fun capabilities(): GameStreamNativeCapabilities =
        engine?.capabilities() ?: GameStreamNativeCapabilities.unavailable()

    fun bind(next: GameStreamNativeBinding) {
        val previous: GameStreamNativeBinding?
        val callbacks: List<(GameStreamNativeOutcome) -> Unit>
        synchronized(this) {
            previous = binding
            if (previous == next) return
            generation += 1
            binding = next
            callbacks = operations.values.flatMap { it.callbacks }
            operations.clear()
        }
        previous?.let { engine?.retire(it.sessionId) }
        val failure = GameStreamNativeOutcome.Failure(GameStreamNativeFailure("cancelled"))
        callbacks.forEach { it(failure) }
    }

    fun execute(
        expectedSessionId: String,
        expectedEpoch: Long,
        command: GameStreamNativeCommand,
        callback: (GameStreamNativeOutcome) -> Unit,
    ) {
        val active: GameStreamNativeBinding
        val leaseGeneration: Long
        val nativeEngine: GameStreamNativeEngine?
        synchronized(this) {
            active = binding ?: gameStreamFail("staleSession")
            if (active.sessionId != expectedSessionId || active.epoch != expectedEpoch ||
                command.sessionId != active.sessionId
            ) gameStreamFail("staleSession")

            val fingerprint = "${command.sessionId}:${command.commandId}:${command.requestId}:${command.intent.wire}:${command.revisions}:${command.quality}"
            val existing = operations[command.intent]
            if (existing != null) {
                if (existing.fingerprint != fingerprint) gameStreamFail("idempotencyConflict")
                existing.terminal?.let { callback(it); return }
                existing.callbacks += callback
                return
            }
            if (operations.size >= GameStreamNativeIntent.entries.size) gameStreamFail("busy")
            leaseGeneration = generation
            operations[command.intent] = Operation(fingerprint, leaseGeneration, mutableListOf(callback))
            nativeEngine = engine
        }

        if (nativeEngine == null) {
            complete(
                command,
                leaseGeneration,
                null,
                GameStreamNativeFailure("engineUnavailable"),
            )
            return
        }
        try {
            synchronized(this) {
                if (binding !== active || generation != leaseGeneration) return
                nativeEngine.execute(command, active.credentialHandle.forEngine()) { receipt, failure ->
                    complete(command, leaseGeneration, receipt, failure)
                }
            }
        } catch (failure: GameStreamNativeFailure) {
            complete(command, leaseGeneration, null, failure)
        } catch (_: Exception) {
            complete(command, leaseGeneration, null, GameStreamNativeFailure("unknownEffect"))
        }
    }

    private fun complete(
        command: GameStreamNativeCommand,
        leaseGeneration: Long,
        receipt: GameStreamEngineReceipt?,
        failure: GameStreamNativeFailure?,
    ) {
        val callbacks: List<(GameStreamNativeOutcome) -> Unit>
        val outcome: GameStreamNativeOutcome
        synchronized(this) {
            val current = binding
            val operation = operations[command.intent]
            if (current == null || generation != leaseGeneration || operation?.generation != leaseGeneration ||
                current.sessionId != command.sessionId
            ) {
                outcome = GameStreamNativeOutcome.Failure(GameStreamNativeFailure("staleSession"))
                callbacks = operation?.callbacks?.toList().orEmpty()
                operation?.callbacks?.clear()
            } else {
                outcome = try {
                    when {
                        failure != null && receipt == null -> GameStreamNativeOutcome.Failure(failure)
                        failure == null && receipt != null -> GameStreamNativeOutcome.Success(receipt.validatedFor(command))
                        else -> GameStreamNativeOutcome.Failure(GameStreamNativeFailure("invalidReceipt"))
                    }
                } catch (invalid: GameStreamNativeFailure) {
                    GameStreamNativeOutcome.Failure(invalid)
                }
                operation.terminal = outcome
                callbacks = operation.callbacks.toList()
                operation.callbacks.clear()
            }
        }
        callbacks.forEach { it(outcome) }
    }

    fun retire(expectedSessionId: String? = null, expectedEpoch: Long? = null) {
        val previous: GameStreamNativeBinding?
        val callbacks: List<(GameStreamNativeOutcome) -> Unit>
        synchronized(this) {
            previous = binding
            if (expectedSessionId != null && previous?.sessionId != expectedSessionId) gameStreamFail("staleSession")
            if (expectedEpoch != null && previous?.epoch != expectedEpoch) gameStreamFail("staleSession")
            generation += 1
            binding = null
            callbacks = operations.values.flatMap { it.callbacks }
            operations.clear()
        }
        previous?.let { engine?.retire(it.sessionId) }
        val failure = GameStreamNativeOutcome.Failure(GameStreamNativeFailure("cancelled"))
        callbacks.forEach { it(failure) }
    }
}
