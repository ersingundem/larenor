package com.ersingundem.larenor.game

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GameStreamNativeAdapterTest {
    private val ids = (1..9).associateWith { it.toString().repeat(32) }

    private fun binding(epoch: Long = 7) = GameStreamNativeBinding.parse(mapOf(
        "sessionId" to ids.getValue(1),
        "epoch" to epoch,
        "accountRevision" to 2,
        "routeRevision" to 3,
        "lifecycleRevision" to 4,
        "idleRevision" to 5,
        "interactionRevision" to 6,
        "credentialHandle" to ids.getValue(9),
    ))

    private fun command(request: String = ids.getValue(3), intent: String = "stream") =
        GameStreamNativeCommand.parse(mapOf(
            "sessionId" to ids.getValue(1),
            "commandId" to ids.getValue(2),
            "requestId" to request,
            "intent" to intent,
            "hostId" to ids.getValue(4),
            "appId" to ids.getValue(5),
            "displayId" to 1,
            "codecId" to ids.getValue(6),
            "networkId" to ids.getValue(7),
            "policyId" to ids.getValue(8),
            "revisions" to mapOf(
                "hostRevision" to 10,
                "pairingRevision" to 11,
                "appRevision" to 12,
                "displayRevision" to 13,
                "codecRevision" to 14,
                "networkRevision" to 15,
                "policyRevision" to 16,
            ),
            "quality" to qualityMap(),
        ))

    private fun receipt(command: GameStreamNativeCommand) = GameStreamEngineReceipt(
        sessionId = command.sessionId,
        commandId = command.commandId,
        requestId = command.requestId,
        intent = command.intent,
        revisions = command.revisions,
        quality = command.quality,
        accepted = true,
        observedState = "streaming",
        readbackRevision = 17,
    )

    private fun reject(code: String, action: () -> Unit) {
        try {
            action()
            fail("Expected $code")
        } catch (failure: GameStreamNativeFailure) {
            assertEquals(code, failure.code)
            assertEquals(setOf("code", "retryable"), failure.publicDetails().keys)
        }
    }

    @Test fun contractIsStrictBoundedAndCredentialHandleIsOpaque() {
        val parsed = binding()
        assertEquals("GameStreamNativeBinding(<redacted>)", parsed.toString())
        assertEquals("GameStreamCredentialHandle(<redacted>)", parsed.credentialHandle.toString())
        assertFalse(parsed.toString().contains(ids.getValue(9)))
        reject("invalidRequest") {
            GameStreamNativeBinding.parse(bindingMap() + ("token" to "secret"))
        }
        reject("invalidCredentialHandle") {
            GameStreamNativeBinding.parse(bindingMap() + ("credentialHandle" to "raw-password"))
        }
        reject("invalidRequest") {
            GameStreamNativeCommand.parse(commandMap() + ("displayId" to 64))
        }
        reject("invalidRequest") {
            GameStreamNativeBinding.parse(bindingMap() + ("routeRevision" to 3.0))
        }
        reject("unsupported") {
            GameStreamNativeCommand.parse(commandMap() + ("quality" to qualityMap() + ("secureSurface" to false)))
        }
        assertEquals(4, GameStreamNativeIntent.entries.size)
    }

    @Test fun unavailableRuntimeFailsClosedAndConsumesTheIntentIdempotently() {
        val adapter = GameStreamNativeAdapter(null)
        adapter.bind(binding())
        val outcomes = mutableListOf<GameStreamNativeOutcome>()
        val command = command()
        adapter.execute(command.sessionId, 7, command, outcomes::add)
        adapter.execute(command.sessionId, 7, command, outcomes::add)
        assertEquals(2, outcomes.size)
        assertTrue(outcomes.all {
            it is GameStreamNativeOutcome.Failure && it.failure.code == "engineUnavailable"
        })
        assertEquals("unavailable", adapter.capabilities().availability)
        assertNull(adapter.capabilities().engineRevision)
        reject("idempotencyConflict") {
            adapter.execute(command.sessionId, 7, command(request = "a".repeat(32))) {}
        }
    }

    @Test fun duplicateInflightDispatchesOnceAndExactReadbackCompletesBoth() {
        val engine = DelayedEngine()
        val adapter = GameStreamNativeAdapter(engine)
        adapter.bind(binding())
        val outcomes = mutableListOf<GameStreamNativeOutcome>()
        val command = command()
        adapter.execute(command.sessionId, 7, command, outcomes::add)
        adapter.execute(command.sessionId, 7, command, outcomes::add)
        assertEquals(1, engine.executeCalls)
        assertEquals(ids.getValue(9), engine.seenCredentialHandle)
        assertTrue(outcomes.isEmpty())
        engine.complete(receipt(command))
        assertEquals(2, outcomes.size)
        assertTrue(outcomes.all { it is GameStreamNativeOutcome.Success })
    }

    @Test fun routeEpochRetirementCancelsPendingAndRejectsLateCallback() {
        val engine = DelayedEngine()
        val adapter = GameStreamNativeAdapter(engine)
        adapter.bind(binding())
        val outcomes = mutableListOf<GameStreamNativeOutcome>()
        val command = command()
        adapter.execute(command.sessionId, 7, command, outcomes::add)
        adapter.retire(command.sessionId, 7)
        assertEquals(1, engine.retireCalls)
        assertEquals("cancelled", (outcomes.single() as GameStreamNativeOutcome.Failure).failure.code)
        engine.complete(receipt(command))
        assertEquals(1, outcomes.size)
        reject("staleSession") { adapter.execute(command.sessionId, 7, command) {} }
        adapter.bind(binding(epoch = 8))
        reject("staleSession") { adapter.execute(command.sessionId, 7, command) {} }
    }

    @Test fun replacementBindingCompletesTheOldLeaseAsCancelled() {
        val engine = DelayedEngine()
        val adapter = GameStreamNativeAdapter(engine)
        adapter.bind(binding())
        val outcomes = mutableListOf<GameStreamNativeOutcome>()
        val command = command()
        adapter.execute(command.sessionId, 7, command, outcomes::add)
        adapter.bind(binding(epoch = 8))
        assertEquals("cancelled", (outcomes.single() as GameStreamNativeOutcome.Failure).failure.code)
        assertEquals(1, engine.retireCalls)
        engine.complete(receipt(command))
        assertEquals(1, outcomes.size)
    }

    @Test fun oldLeaseCallbackCannotCancelTheNewLeaseCommand() {
        val engine = DelayedEngine()
        val adapter = GameStreamNativeAdapter(engine)
        adapter.bind(binding())
        val oldCommand = command()
        val oldOutcomes = mutableListOf<GameStreamNativeOutcome>()
        adapter.execute(oldCommand.sessionId, 7, oldCommand, oldOutcomes::add)

        adapter.bind(binding(epoch = 8))
        assertEquals("cancelled", (oldOutcomes.single() as GameStreamNativeOutcome.Failure).failure.code)
        val newCommand = command(request = "a".repeat(32))
        val newOutcomes = mutableListOf<GameStreamNativeOutcome>()
        adapter.execute(newCommand.sessionId, 8, newCommand, newOutcomes::add)

        engine.complete(receipt(oldCommand), index = 0)
        assertTrue(newOutcomes.isEmpty())
        engine.complete(receipt(newCommand), index = 1)
        assertEquals(1, newOutcomes.size)
        assertTrue(newOutcomes.single() is GameStreamNativeOutcome.Success)
    }

    @Test fun mismatchedEngineReadbackNeverBecomesSuccess() {
        val engine = DelayedEngine()
        val adapter = GameStreamNativeAdapter(engine)
        adapter.bind(binding())
        val outcomes = mutableListOf<GameStreamNativeOutcome>()
        val command = command()
        adapter.execute(command.sessionId, 7, command, outcomes::add)
        engine.complete(receipt(command).copy(requestId = "a".repeat(32)))
        assertEquals("invalidReceipt", (outcomes.single() as GameStreamNativeOutcome.Failure).failure.code)
    }

    private fun bindingMap() = mapOf<String, Any>(
        "sessionId" to ids.getValue(1), "epoch" to 7,
        "accountRevision" to 2, "routeRevision" to 3,
        "lifecycleRevision" to 4, "idleRevision" to 5,
        "interactionRevision" to 6, "credentialHandle" to ids.getValue(9),
    )

    private fun commandMap() = mapOf<String, Any>(
        "sessionId" to ids.getValue(1), "commandId" to ids.getValue(2),
        "requestId" to ids.getValue(3), "intent" to "stream",
        "hostId" to ids.getValue(4), "appId" to ids.getValue(5), "displayId" to 1,
        "codecId" to ids.getValue(6), "networkId" to ids.getValue(7),
        "policyId" to ids.getValue(8),
        "revisions" to mapOf(
            "hostRevision" to 10, "pairingRevision" to 11, "appRevision" to 12,
            "displayRevision" to 13, "codecRevision" to 14,
            "networkRevision" to 15, "policyRevision" to 16,
        ),
        "quality" to qualityMap(),
    )

    private fun qualityMap() = mapOf<String, Any>(
        "widthPixels" to 2560, "heightPixels" to 1600,
        "framesPerSecond" to 120, "bitrateKbps" to 24576,
        "frameQueueDepth" to 3, "inputQueueDepth" to 32,
        "secureSurface" to true,
    )

    private class DelayedEngine : GameStreamNativeEngine {
        var executeCalls = 0
        var retireCalls = 0
        var seenCredentialHandle: String? = null
        private val callbacks = mutableListOf<(GameStreamEngineReceipt?, GameStreamNativeFailure?) -> Unit>()

        override fun capabilities() = GameStreamNativeCapabilities(
            "available", "fixture-1", GameStreamNativeIntent.entries.toSet(),
        )

        override fun execute(
            command: GameStreamNativeCommand,
            credentialHandle: String,
            callback: (GameStreamEngineReceipt?, GameStreamNativeFailure?) -> Unit,
        ) {
            executeCalls += 1
            seenCredentialHandle = credentialHandle
            callbacks += callback
        }

        override fun retire(sessionId: String) { retireCalls += 1 }

        fun complete(receipt: GameStreamEngineReceipt, index: Int = callbacks.lastIndex) {
            callbacks[index].invoke(receipt, null)
        }
    }
}
