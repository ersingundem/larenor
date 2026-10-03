package com.ersingundem.larenor.rdp

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import javax.crypto.KeyGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpSafGrantBrokerTest {
    private class Result : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var done = false
        override fun success(result: Any?) { value = result; done = true }
        override fun error(code: String, message: String?, details: Any?) { error = code; done = true }
        override fun notImplemented() { error = "missing"; done = true }
    }

    private class Host : RdpSafGrantHost {
        val launched = mutableListOf<Pair<Intent, Int>>()
        val persisted = mutableMapOf<String, Int>()
        val taken = mutableListOf<Pair<String, Int>>()
        val released = mutableListOf<Pair<String, Int>>()
        var takeFailure = false
        var releaseFailure = false
        var onTake: (() -> Unit)? = null
        var onRelease: (() -> Unit)? = null

        override fun launch(intent: Intent, requestCode: Int) {
            launched += intent to requestCode
        }

        override fun persistedFlags(uri: Uri): Int = persisted[uri.toString()] ?: 0

        override fun take(uri: Uri, flags: Int) {
            onTake?.invoke()
            if (takeFailure) throw SecurityException("fixture")
            taken += uri.toString() to flags
            persisted[uri.toString()] = persistedFlags(uri) or flags
        }

        override fun release(uri: Uri, flags: Int) {
            onRelease?.invoke()
            released += uri.toString() to flags
            if (releaseFailure) throw SecurityException("fixture")
            persisted[uri.toString()] = persistedFlags(uri) and flags.inv()
        }
    }

    @Test
    fun ownedPickerSurvivesStopAndDefersTakeUntilResumedAndFocused() {
        val fixture = fixture()
        val selected = Result()
        fixture.broker.setResumed(true)
        fixture.broker.setWindowFocused(true)
        fixture.broker.select(select(), selected)
        assertEquals(1, fixture.host.launched.size)
        assertEquals(Intent.ACTION_OPEN_DOCUMENT_TREE, fixture.host.launched.single().first.action)
        assertEquals(RdpSafGrantBroker.REQUIRED_FLAGS,
            fixture.host.launched.single().first.flags and RdpSafGrantBroker.REQUIRED_FLAGS)

        fixture.broker.setResumed(false) // DocumentsUI legitimately stops the owner Activity.
        fixture.broker.setWindowFocused(false)
        assertTrue(fixture.broker.onActivityResult(
            fixture.host.launched.last().second,
            Activity.RESULT_OK,
            resultIntent(),
        ))
        assertFalse(selected.done)
        assertTrue(fixture.host.taken.isEmpty())

        fixture.broker.setResumed(true)
        assertTrue(fixture.host.taken.isEmpty())
        fixture.broker.setWindowFocused(true)

        assertNull(selected.error)
        val receipt = selected.value as Map<*, *>
        assertEquals("prepared", receipt["state"])
        assertEquals(RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS, fixture.host.taken.single().second)
        assertEquals(RdpSafGrantPhase.PREPARED, fixture.store.read().single().phase)
        assertEquals(URI, fixture.store.read().single().uri)
    }

    @Test
    fun missingFlagsCancelAndStaleCallbackHaveNoPermissionEffect() {
        val fixture = fixture()
        fixture.foreground()
        val selected = Result()
        fixture.broker.select(select(), selected)
        val staleCode = fixture.host.launched.last().second
        val foreignCancel = Result()
        fixture.broker.cancel(
            mapOf("schemaVersion" to 5, "requestId" to OTHER_SELECT),
            foreignCancel,
        )
        assertNull(foreignCancel.error)
        assertFalse(selected.done)
        val cancelled = Result()
        fixture.broker.cancel(mapOf("schemaVersion" to 5, "requestId" to SELECT_REQUEST), cancelled)
        assertNull(cancelled.error)
        assertEquals("cancelled", selected.error)
        assertTrue(fixture.host.taken.isEmpty())
        val second = Result()
        fixture.broker.select(select(OTHER_SELECT), second)
        val successorCode = fixture.host.launched.last().second
        assertTrue(staleCode != successorCode)
        assertTrue(fixture.broker.onActivityResult(
            staleCode,
            Activity.RESULT_OK,
            resultIntent(),
        ))
        assertTrue(fixture.host.taken.isEmpty())
        assertFalse(second.done)

        fixture.broker.onActivityResult(
            successorCode,
            Activity.RESULT_OK,
            resultIntent(Intent.FLAG_GRANT_READ_URI_PERMISSION),
        )
        assertEquals("permission_denied", second.error)
        assertTrue(fixture.host.taken.isEmpty())
    }

    @Test
    fun activationIsExactReplayAndStaleAuthorityCannotMutateGrant() {
        val fixture = prepared()
        val record = fixture.store.read().single()
        val activated = Result()
        fixture.broker.activate(grant(record, ACTIVATE_REQUEST), activated)
        assertEquals("active", (activated.value as Map<*, *>)["state"])

        val replay = Result()
        fixture.broker.activate(grant(record, ACTIVATE_REQUEST), replay)
        assertEquals(activated.value, replay.value)

        val changed = Result()
        fixture.broker.activate(grant(record, ACTIVATE_REQUEST) + ("expectedGrantRevision" to 2L), changed)
        assertEquals("invalid_request", changed.error)
        assertEquals(RdpSafGrantPhase.ACTIVE, fixture.store.read().single().phase)

        val stale = Result()
        fixture.broker.observe(grant(record, OBSERVE_REQUEST, otherAuthority()), stale)
        assertEquals("authority_changed", stale.error)
        assertEquals(RdpSafGrantPhase.ACTIVE, fixture.store.read().single().phase)
    }

    @Test
    fun activationReplayReconcilesFullExternalRevocationBeforeReturning() {
        val fixture = prepared()
        val record = fixture.store.read().single()
        fixture.broker.activate(grant(record, ACTIVATE_REQUEST), Result())
        fixture.host.persisted[URI] = 0

        val replay = Result()
        fixture.broker.activate(grant(record, ACTIVATE_REQUEST), replay)

        assertEquals("unavailable", replay.error)
        val reconciled = fixture.store.read().single()
        assertEquals(RdpSafGrantPhase.RETIRED, reconciled.phase)
        assertNull(reconciled.uri)
        assertEquals(0, reconciled.acquiredFlags)
        assertEquals(1, fixture.host.taken.size)
        assertTrue(fixture.host.released.isEmpty())
    }

    @Test
    fun activationReplayReconcilesPartialExternalRevocationBeforeReturning() {
        val fixture = prepared()
        val record = fixture.store.read().single()
        fixture.broker.activate(grant(record, ACTIVATE_REQUEST), Result())
        fixture.host.persisted[URI] = Intent.FLAG_GRANT_READ_URI_PERMISSION

        val replay = Result()
        fixture.broker.activate(grant(record, ACTIVATE_REQUEST), replay)

        assertEquals("unavailable", replay.error)
        val reconciled = fixture.store.read().single()
        assertEquals(RdpSafGrantPhase.RETIRE_INTENT, reconciled.phase)
        assertEquals(URI, reconciled.uri)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, reconciled.acquiredFlags)
        assertEquals(1, fixture.host.taken.size)
        assertTrue(fixture.host.released.isEmpty())
    }

    @Test
    fun retirementPersistsDispatchBeforeReleaseAndNeverReplaysUncertainEffect() {
        val fixture = prepared()
        val record = fixture.store.read().single()
        fixture.host.releaseFailure = true
        fixture.host.onRelease = {
            assertEquals(RdpSafGrantPhase.RELEASE_DISPATCHED, fixture.store.read().single().phase)
        }
        val retired = Result()
        fixture.broker.retire(grant(record, RETIRE_REQUEST), retired)
        assertNull(retired.error)
        assertEquals("unknown", (retired.value as Map<*, *>)["state"])
        assertEquals(RdpSafGrantPhase.RELEASE_DISPATCHED, fixture.store.read().single().phase)
        assertEquals(URI, fixture.store.read().single().uri)
        assertEquals(
            RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS,
            fixture.store.read().single().acquiredFlags,
        )
        assertEquals(1, fixture.host.released.size)

        val retry = Result()
        fixture.host.releaseFailure = false
        fixture.broker.retire(grant(record, RETIRE_REQUEST), retry)
        assertNull(retry.error)
        assertEquals("unknown", (retry.value as Map<*, *>)["state"])
        assertEquals(1, fixture.host.released.size)

        // A later readback may prove the uncertain release completed, without redispatch.
        fixture.host.persisted[URI] = 0
        val observed = Result()
        fixture.broker.observe(grant(record, OBSERVE_REQUEST), observed)
        assertEquals("retired", (observed.value as Map<*, *>)["state"])
        assertEquals(1, fixture.host.released.size)
        assertNull(fixture.store.read().single().uri)
    }

    @Test
    fun fullExternalRevocationBecomesRetiredWithoutReleaseOrReacquire() {
        val fixture = prepared()
        val record = fixture.store.read().single()
        fixture.host.persisted[URI] = 0

        val observed = Result()
        fixture.broker.observe(grant(record, OBSERVE_REQUEST), observed)

        assertEquals("retired", (observed.value as Map<*, *>)["state"])
        val retired = fixture.store.read().single()
        assertEquals(RdpSafGrantPhase.RETIRED, retired.phase)
        assertNull(retired.uri)
        assertEquals(0, retired.acquiredFlags)
        assertTrue(fixture.host.taken.size == 1)
        assertTrue(fixture.host.released.isEmpty())
    }

    @Test
    fun partialExternalRevocationKeepsLiveOwnedBitUnknownUntilExplicitRetire() {
        val fixture = prepared()
        val record = fixture.store.read().single()
        fixture.host.persisted[URI] = Intent.FLAG_GRANT_READ_URI_PERMISSION

        val observed = Result()
        fixture.broker.observe(grant(record, OBSERVE_REQUEST), observed)

        assertEquals("unknown", (observed.value as Map<*, *>)["state"])
        val unknown = fixture.store.read().single()
        assertEquals(RdpSafGrantPhase.RETIRE_INTENT, unknown.phase)
        assertEquals(URI, unknown.uri)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, unknown.acquiredFlags)
        assertTrue(fixture.host.released.isEmpty())

        val activation = Result()
        fixture.broker.activate(grant(record, ACTIVATE_REQUEST), activation)
        assertEquals("unavailable", activation.error)
        assertEquals(1, fixture.host.taken.size)

        val retired = Result()
        fixture.broker.retire(grant(record, RETIRE_REQUEST), retired)
        assertEquals("retired", (retired.value as Map<*, *>)["state"])
        assertEquals(
            listOf(URI to Intent.FLAG_GRANT_READ_URI_PERMISSION),
            fixture.host.released,
        )
        assertEquals(0, fixture.host.persisted[URI])
    }

    @Test
    fun preexistingAndSharedPermissionsAreNeverReleased() {
        val fixture = fixture()
        fixture.host.persisted[URI] = RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS
        fixture.foreground()
        val selected = Result()
        fixture.broker.select(select(), selected)
        fixture.broker.onActivityResult(fixture.host.launched.last().second, Activity.RESULT_OK, resultIntent())
        val record = fixture.store.read().single()
        assertEquals(0, record.acquiredFlags)

        val retired = Result()
        fixture.broker.retire(grant(record, RETIRE_REQUEST), retired)
        assertEquals("retired", (retired.value as Map<*, *>)["state"])
        assertTrue(fixture.host.released.isEmpty())
        assertEquals(RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS, fixture.host.persisted[URI])
    }

    @Test
    fun acquiredPermissionDebtTransfersWhenOwnerRetiresBeforeSharedGrant() {
        val fixture = fixture()
        fixture.foreground()
        val first = Result()
        fixture.broker.select(select(), first)
        fixture.broker.onActivityResult(fixture.host.launched.last().second, Activity.RESULT_OK, resultIntent())
        val firstRecord = fixture.store.read().single()
        assertEquals(RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS, firstRecord.acquiredFlags)

        val second = Result()
        fixture.broker.select(select(OTHER_SELECT, otherAuthority()), second)
        fixture.broker.onActivityResult(fixture.host.launched.last().second, Activity.RESULT_OK, resultIntent())
        val secondRecord = fixture.store.read().single { it.selectRequestId == OTHER_SELECT }
        assertEquals(0, secondRecord.acquiredFlags)

        val retireFirst = Result()
        fixture.broker.retire(grant(firstRecord, RETIRE_REQUEST), retireFirst)
        assertEquals("retired", (retireFirst.value as Map<*, *>)["state"])
        val transferred = fixture.store.read().single { it.grantId == secondRecord.grantId }
        assertEquals(RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS, transferred.acquiredFlags)
        assertTrue(fixture.host.released.isEmpty())

        val retireSecond = Result()
        fixture.broker.retire(
            grant(transferred, SECOND_RETIRE_REQUEST, otherAuthority()),
            retireSecond,
        )
        assertEquals("retired", (retireSecond.value as Map<*, *>)["state"])
        assertEquals(1, fixture.host.released.size)
        assertEquals(0, fixture.host.persisted[URI])
    }

    @Test
    fun retiringNonOwnerFirstLeavesOriginalPermissionDebtIntact() {
        val fixture = fixture()
        fixture.foreground()
        val first = Result()
        fixture.broker.select(select(), first)
        fixture.broker.onActivityResult(fixture.host.launched.last().second, Activity.RESULT_OK, resultIntent())
        val firstRecord = fixture.store.read().single()
        val second = Result()
        fixture.broker.select(select(OTHER_SELECT, otherAuthority()), second)
        fixture.broker.onActivityResult(fixture.host.launched.last().second, Activity.RESULT_OK, resultIntent())
        val secondRecord = fixture.store.read().single { it.selectRequestId == OTHER_SELECT }

        val retireSecond = Result()
        fixture.broker.retire(
            grant(secondRecord, SECOND_RETIRE_REQUEST, otherAuthority()),
            retireSecond,
        )
        assertEquals("retired", (retireSecond.value as Map<*, *>)["state"])
        assertTrue(fixture.host.released.isEmpty())
        assertEquals(
            RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS,
            fixture.store.read().single { it.grantId == firstRecord.grantId }.acquiredFlags,
        )

        val retireFirst = Result()
        fixture.broker.retire(grant(firstRecord, RETIRE_REQUEST), retireFirst)
        assertEquals("retired", (retireFirst.value as Map<*, *>)["state"])
        assertEquals(1, fixture.host.released.size)
        assertEquals(0, fixture.host.persisted[URI])
    }

    @Test
    fun restartReconcilesObservedAcquireWithoutRepeatingTake() {
        val fixture = fixture()
        val authority = authority()
        val record = RdpSafGrantRecord(
            authority, GRANT_ID, 1, RdpSafGrantPhase.ACQUIRE_INTENT,
            SELECT_REQUEST, fixture.now, fixture.now + 30_000, URI,
            RdpSafGrantBroker.REQUIRED_FLAGS, 0, RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS,
            null, null,
        )
        fixture.store.replace(listOf(record))
        fixture.host.persisted[URI] = RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS
        val observed = Result()
        fixture.broker.observe(grant(record, OBSERVE_REQUEST), observed)
        assertEquals("prepared", (observed.value as Map<*, *>)["state"])
        assertTrue(fixture.host.taken.isEmpty())
        assertEquals(RdpSafGrantPhase.PREPARED, fixture.store.read().single().phase)
    }

    private data class Fixture(
        val store: RdpSafGrantStore,
        val host: Host,
        val broker: RdpSafGrantBroker,
        var now: Long,
    ) {
        fun foreground() {
            broker.setResumed(true)
            broker.setWindowFocused(true)
        }
    }

    private fun fixture(): Fixture {
        var now = 1_000L
        var grantSequence = 0
        val root = File(
            RuntimeEnvironment.getApplication().cacheDir,
            "rdp-saf-broker-${System.nanoTime()}",
        )
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = RdpSafGrantStore(
            RuntimeEnvironment.getApplication(),
            testKeyProvider = { key },
            rootOverride = root,
        )
        val host = Host()
        val broker = RdpSafGrantBroker(
            host,
            store,
            Handler(Looper.getMainLooper()),
            now = { now },
            grantId = {
                grantSequence++
                if (grantSequence == 1) GRANT_ID else "%032x".format(grantSequence)
            },
        )
        return Fixture(store, host, broker, now)
    }

    private fun prepared(): Fixture = fixture().also { fixture ->
        fixture.foreground()
        val result = Result()
        fixture.broker.select(select(), result)
        fixture.broker.onActivityResult(fixture.host.launched.last().second, Activity.RESULT_OK, resultIntent())
        assertNull(result.error)
    }

    private fun select(
        requestId: String = SELECT_REQUEST,
        authority: Map<String, Any?> = authorityMap(),
    ) = mapOf<String, Any?>(
        "schemaVersion" to 5,
        "requestId" to requestId,
        "authority" to authority,
    )

    private fun grant(
        record: RdpSafGrantRecord,
        requestId: String,
        authority: Map<String, Any?> = authorityMap(),
    ) = mapOf<String, Any?>(
        "schemaVersion" to 5,
        "requestId" to requestId,
        "authority" to authority,
        "grantId" to record.grantId,
        "expectedGrantRevision" to record.grantRevision,
    )

    private fun resultIntent(flags: Int = RdpSafGrantBroker.REQUIRED_FLAGS) = Intent().apply {
        data = Uri.parse(URI)
        this.flags = flags
    }

    private fun authority() = RdpSafContract.authority(authorityMap())
    private fun authorityMap() = mapOf<String, Any?>(
        "schemaVersion" to 5,
        "namespaceDigest" to "a".repeat(64),
        "profileRef" to "b".repeat(64),
        "profileRevision" to 1L,
    )
    private fun otherAuthority() = authorityMap() + ("profileRevision" to 2L)

    companion object {
        private const val SELECT_REQUEST = "11111111-1111-4111-8111-111111111111"
        private const val OTHER_SELECT = "12111111-1111-4111-8111-111111111111"
        private const val ACTIVATE_REQUEST = "22222222-2222-4222-8222-222222222222"
        private const val OBSERVE_REQUEST = "33333333-3333-4333-8333-333333333333"
        private const val RETIRE_REQUEST = "44444444-4444-4444-8444-444444444444"
        private const val SECOND_RETIRE_REQUEST = "55555555-5555-4555-8555-555555555555"
        private const val GRANT_ID = "0123456789abcdef0123456789abcdef"
        private const val URI = "content://owned/tree/document"
    }
}
