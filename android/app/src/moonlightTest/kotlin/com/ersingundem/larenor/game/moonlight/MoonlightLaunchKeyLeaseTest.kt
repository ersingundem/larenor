package com.ersingundem.larenor.game.moonlight

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MoonlightLaunchKeyLeaseTest {
    private var now = 1_000L
    private val scheduled = mutableListOf<Pair<Long, () -> Unit>>()
    private val store = MoonlightLaunchKeyLeaseStore(
        nowElapsedMillis = { now },
        schedule = { delay, block -> scheduled += delay to block },
    )

    @Test
    fun exactLaunchKeyAIsConsumedOnceForResumeAndCallerStorageIsWiped() {
        val launched = ByteArray(16) { (it + 1).toByte() }
        val expected = launched.copyOf()
        val generatedByOldConstructor = ByteArray(16) { (it + 33).toByte() }
        assertFalse(expected.contentEquals(generatedByOldConstructor))

        publish(owner(), launched, 42, 30_000)
        launched.fill(0)
        val token = "a".repeat(32)
        assertEquals(token, store.bindIssued(owner()) { token to token })

        lateinit var borrowed: ByteArray
        store.consume(token).use { key, keyId ->
            borrowed = key
            assertArrayEquals(expected, key)
            assertEquals(42, keyId)
        }
        assertTrue(borrowed.all { it == 0.toByte() })
        expectCode("unknown_effect") { store.consume(token) }
    }

    @Test
    fun matchingRunningAppUsesResumeWithoutQuitAndStillEstablishesFreshKey() {
        assertEquals(
            MoonlightProviderLaunchPlan("resume", quitExistingApp = false),
            providerLaunchPlan(currentAppId = 42, selectedAppId = 42),
        )
        assertEquals(
            MoonlightProviderLaunchPlan("launch", quitExistingApp = false),
            providerLaunchPlan(currentAppId = 0, selectedAppId = 42),
        )
        assertEquals(
            MoonlightProviderLaunchPlan("launch", quitExistingApp = true),
            providerLaunchPlan(currentAppId = 7, selectedAppId = 42),
        )

        val key = ByteArray(16) { (it + 11).toByte() }
        publish(owner(), key, 42, 30_000)
        val token = "5".repeat(32)
        store.bindIssued(owner()) { Unit to token }
        store.consume(token).use { consumed, keyId ->
            assertArrayEquals(key, consumed)
            assertEquals(42, keyId)
        }
    }

    @Test
    fun concurrentMaterialUseTransfersOwnershipToExactlyOneCaller() {
        val material = MoonlightLaunchKeyMaterial(ByteArray(16) { 7 }, 9)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val first = executor.submit {
                material.use { key, keyId ->
                    entered.countDown()
                    assertTrue(release.await(2, TimeUnit.SECONDS))
                    assertTrue(key.all { it == 7.toByte() })
                    assertEquals(9, keyId)
                }
            }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            expectCode("authority_changed") {
                material.use { _, _ -> fail("concurrent second caller consumed the key") }
            }
            release.countDown()
            first.get(2, TimeUnit.SECONDS)
        } finally {
            release.countDown()
            executor.shutdownNow()
            material.close()
        }
    }

    @Test
    fun transferredMaterialIsWipedWhenTheConstructorBlockThrows() {
        val material = MoonlightLaunchKeyMaterial(ByteArray(16) { 6 }, 11)
        lateinit var borrowed: ByteArray
        try {
            material.use { key, _ ->
                borrowed = key
                throw IllegalStateException("fixture")
            }
            fail("constructor failure was swallowed")
        } catch (_: IllegalStateException) {
            // Expected.
        }
        assertTrue(borrowed.all { it == 0.toByte() })
        expectCode("authority_changed") {
            material.use { _, _ -> fail("failed material was reused") }
        }
    }

    @Test
    fun wrongOwnerAndForeignTokenCannotConsumeOrRetireTheExactSuccessorKey() {
        publish(owner(), ByteArray(16) { 1 }, 1, 30_000)
        expectCode("authority_changed") {
            store.bindIssued(owner().copy(appRevision = 2)) {
                Unit to "b".repeat(32)
            }
        }
        val originalToken = "b".repeat(32)
        store.bindIssued(owner()) { Unit to originalToken }
        store.consume(originalToken).close()

        val successor = owner().copy(sessionId = "9".repeat(32), sessionRevision = 2)
        publish(owner(), ByteArray(16) { 2 }, 2, 30_000)
        publish(successor, ByteArray(16) { 3 }, 3, 30_000)
        val successorToken = "c".repeat(32)
        store.bindIssued(successor) { Unit to successorToken }
        expectCode("authority_changed") { store.consume("d".repeat(32)) }
        store.consume(successorToken).use { key, keyId ->
            assertTrue(key.all { it == 3.toByte() })
            assertEquals(3, keyId)
        }
    }

    @Test
    fun lateOldProviderCompletionCannotOverwriteActivatedSuccessorBinding() {
        val old = owner()
        val successor = owner().copy(
            bindingId = "8".repeat(32),
            bindingRevision = 2,
            sessionId = "9".repeat(32),
            sessionRevision = 2,
        )
        store.activateBinding(old.bindingId, old.bindingRevision)
        val oldReservation = store.reserve(old, 30_000)

        store.activateBinding(successor.bindingId, successor.bindingRevision)
        val successorReservation = store.reserve(successor, 30_000)
        store.publish(successorReservation, ByteArray(16) { 9 }, 9)

        expectCode("authority_changed") {
            store.publish(oldReservation, ByteArray(16) { 1 }, 1)
        }
        val token = "6".repeat(32)
        store.bindIssued(successor) { Unit to token }
        store.consume(token).use { key, keyId ->
            assertTrue(key.all { it == 9.toByte() })
            assertEquals(9, keyId)
        }
    }

    @Test
    fun timeoutAndEveryExactRetirementFenceRemoveTheProcessPrivateKey() {
        publish(owner(), ByteArray(16) { 4 }, 4, 1_000)
        assertEquals(1_000L, scheduled.single().first)
        now += 1_000
        scheduled.removeAt(0).second.invoke()
        expectCode("unknown_effect") {
            store.bindIssued(owner()) { Unit to "e".repeat(32) }
        }

        publish(owner(), ByteArray(16) { 5 }, 5, 30_000)
        store.retireSession(
            owner().bindingId,
            owner().bindingRevision,
            owner().sessionId,
            owner().sessionRevision,
        )
        expectCode("unknown_effect") {
            store.bindIssued(owner()) { Unit to "f".repeat(32) }
        }

        publish(owner(), ByteArray(16) { 6 }, 6, 30_000)
        store.retireBinding("9".repeat(32), owner().bindingRevision)
        val retainedToken = "0".repeat(32)
        store.bindIssued(owner()) { Unit to retainedToken }
        store.consume(retainedToken).close()

        publish(owner(), ByteArray(16) { 6 }, 6, 30_000)
        store.retireBinding(owner().bindingId, owner().bindingRevision)
        expectCode("unknown_effect") {
            store.bindIssued(owner()) { Unit to "9".repeat(32) }
        }

        publish(owner(), ByteArray(16) { 6 }, 6, 30_000)
        store.retireAuthority(owner().authorityFingerprint)
        expectCode("unknown_effect") {
            store.bindIssued(owner()) { Unit to "1".repeat(32) }
        }

        publish(owner(), ByteArray(16) { 7 }, 7, 30_000)
        val token = "2".repeat(32)
        store.bindIssued(owner()) { Unit to token }
        store.retireToken(token)
        expectCode("unknown_effect") { store.consume(token) }
    }

    @Test
    fun rejectedIssueAndScheduledFailureRetireTheUnboundKey() {
        publish(owner(), ByteArray(16) { 8 }, 8, 30_000)
        try {
            store.bindIssued<Unit>(owner()) { throw IllegalStateException("fixture") }
            fail("issue failure was accepted")
        } catch (_: IllegalStateException) {
            // Expected.
        }
        expectCode("unknown_effect") {
            store.bindIssued(owner()) { Unit to "3".repeat(32) }
        }

        val failedScheduleStore = MoonlightLaunchKeyLeaseStore(
            nowElapsedMillis = { now },
            schedule = { _, _ -> throw IllegalStateException("fixture") },
        )
        try {
            failedScheduleStore.activateBinding(owner().bindingId, owner().bindingRevision)
            failedScheduleStore.reserve(owner(), 30_000)
            fail("schedule failure was accepted")
        } catch (_: IllegalStateException) {
            // Expected.
        }
        expectCode("unknown_effect") {
            failedScheduleStore.bindIssued(owner()) { Unit to "4".repeat(32) }
        }
    }

    private fun owner() = MoonlightLaunchKeyOwner(
        authorityFingerprint = "a".repeat(64),
        bindingId = "0".repeat(32),
        bindingRevision = 1,
        sessionId = "1".repeat(32),
        sessionRevision = 1,
        hostId = "2".repeat(32),
        hostRevision = 1,
        pairingRevision = 2,
        catalogRevision = 3,
        appId = "3".repeat(32),
        appRevision = 4,
        selectedQualityFingerprint = "b".repeat(64),
        upstreamHostUuid = "owned-upstream-host",
        providerHost = "192.0.2.1",
        providerPort = 47989,
        providerHttpsPort = 47984,
        upstreamAppId = 42,
        uniqueId = "0123456789ABCDEF",
        certificateFingerprint = "c".repeat(64),
    )

    private fun publish(
        owner: MoonlightLaunchKeyOwner,
        key: ByteArray,
        keyId: Int,
        ttlMillis: Long,
    ) {
        store.activateBinding(owner.bindingId, owner.bindingRevision)
        val reservation = store.reserve(owner, ttlMillis)
        store.publish(reservation, key, keyId)
    }

    private fun expectCode(code: String, block: () -> Unit) {
        try {
            block()
            fail("$code was not thrown")
        } catch (failure: MoonlightRuntimeFailure) {
            assertEquals(code, failure.code)
        }
    }
}
