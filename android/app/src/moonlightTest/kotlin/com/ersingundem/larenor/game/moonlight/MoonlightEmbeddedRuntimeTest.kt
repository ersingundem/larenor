package com.ersingundem.larenor.game.moonlight

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.ServiceConnection
import android.os.Looper
import android.view.SurfaceView
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import com.limelight.Game
import com.limelight.binding.audio.AndroidAudioRenderer
import com.limelight.binding.crypto.AndroidCryptoProvider
import com.limelight.binding.input.ControllerHandler
import com.limelight.binding.video.MediaCodecDecoderRenderer
import com.limelight.computers.ComputerDatabaseManager
import com.limelight.computers.IdentityManager
import com.limelight.nvstream.NvConnection
import com.limelight.nvstream.http.ComputerDetails
import com.limelight.nvstream.http.NvHTTP
import com.limelight.nvstream.http.PairingManager
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import java.util.function.Consumer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MoonlightEmbeddedRuntimeTest {
    @get:Rule val temporary = TemporaryFolder()
    private val ids = (1..12).associateWith { Integer.toHexString(it).padStart(32, '0') }

    @After fun clearLease() = MoonlightForegroundLeaseRegistry.clearForTest()

    @Test fun packagedEngineExposesTheActualPairVideoAudioAndInputClasses() {
        assertNotNull(PairingManager::class.java.getDeclaredMethod("pair", String::class.java, String::class.java))
        assertNotNull(NvHTTP::class.java.getDeclaredMethod("getAppList"))
        assertNotNull(NvHTTP::class.java.getDeclaredMethod("cancelPendingRequests"))
        assertNotNull(NvConnection::class.java)
        assertNotNull(Game::class.java)
        assertNotNull(MediaCodecDecoderRenderer::class.java)
        assertNotNull(AndroidAudioRenderer::class.java)
        assertNotNull(ControllerHandler::class.java)
        assertNotNull(Game::class.java.getDeclaredMethod("onConnectionStopStarted"))
        assertNotNull(Game::class.java.getDeclaredMethod("onConnectionStopCompleted"))
        assertNotNull(Game::class.java.getDeclaredMethod(
            "onVideoFrameRendered", Long::class.javaPrimitiveType, Long::class.javaPrimitiveType,
        ))
        assertNotNull(Game::class.java.getDeclaredMethod(
            "onAudioPcmWritten", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
        ))
        assertEquals(
            "moonlight-android-12.2-larenor-embed-v3",
            MoonlightEmbeddedRuntime.ENGINE_REVISION,
        )
    }

    @Test fun stalledPairingRequestCancelsBoundedlyAndReleasesTheSingleWorkerQueue() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val context = MoonlightScopedContext.create(
                RuntimeEnvironment.getApplication(),
                scope(8),
            )
            val http = NvHTTP(
                ComputerDetails.AddressTuple(server.hostName, server.port),
                0,
                "0123456789abcdef",
                null,
                AndroidCryptoProvider(context),
            )
            val executor = Executors.newSingleThreadExecutor()
            try {
                val pairing = executor.submit<PairingManager.PairState> {
                    http.pairingManager.pair(
                        "<root status_code=\"200\"><appversion>7.0.0.0</appversion></root>",
                        "1234",
                    )
                }
                assertNotNull(server.takeRequest(2, TimeUnit.SECONDS))
                val queued = CountDownLatch(1)
                executor.execute(queued::countDown)

                http.cancelPendingRequests()

                assertTrue("a cancelled no-timeout call must release the worker", queued.await(2, TimeUnit.SECONDS))
                try {
                    pairing.get(2, TimeUnit.SECONDS)
                    fail("cancelled pairing unexpectedly completed")
                } catch (expected: ExecutionException) {
                    assertTrue(expected.cause is java.io.IOException)
                }
                assertEquals(1, server.requestCount)
            } finally {
                http.cancelPendingRequests()
                executor.shutdownNow()
            }
        }
    }

    @Test fun pairingCancellationRetainsCallThroughAStalledResponseBody() {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse()
                    .setBody("<root status_code=\"200\"><paired>0</paired></root>")
                    .setBodyDelay(1, TimeUnit.DAYS),
            )
            val context = MoonlightScopedContext.create(
                RuntimeEnvironment.getApplication(),
                scope(7),
            )
            val http = NvHTTP(
                ComputerDetails.AddressTuple(server.hostName, server.port),
                0,
                "0123456789abcdef",
                null,
                AndroidCryptoProvider(context),
            )
            val executor = Executors.newSingleThreadExecutor()
            try {
                val pairing = executor.submit<PairingManager.PairState> {
                    http.pairingManager.pair(
                        "<root status_code=\"200\"><appversion>7.0.0.0</appversion></root>",
                        "1234",
                    )
                }
                assertNotNull(server.takeRequest(2, TimeUnit.SECONDS))
                val queued = CountDownLatch(1)
                executor.execute(queued::countDown)

                http.cancelPendingRequests()

                assertTrue("body-read cancellation must release the worker", queued.await(2, TimeUnit.SECONDS))
                try {
                    pairing.get(2, TimeUnit.SECONDS)
                    fail("cancelled body read unexpectedly completed")
                } catch (expected: ExecutionException) {
                    assertTrue(expected.cause is java.io.IOException)
                }
                assertEquals(1, server.requestCount)
            } finally {
                http.cancelPendingRequests()
                executor.shutdownNow()
            }
        }
    }

    @Test fun pairingFlightCancelBeforeAttachCannotAffectSuccessor() {
        MockWebServer().use { server ->
            val context = MoonlightScopedContext.create(
                RuntimeEnvironment.getApplication(),
                scope(6),
            )
            fun client() = NvHTTP(
                ComputerDetails.AddressTuple(server.hostName, server.port),
                0,
                "0123456789abcdef",
                null,
                AndroidCryptoProvider(context),
            )

            val retired = MoonlightPairingFlight()
            retired.cancel()
            reject("cancelled") { retired.attach(client()) }

            val successorClient = client()
            val successor = MoonlightPairingFlight()
            successor.attach(successorClient)
            retired.cancel()
            successor.requireActive()
            successor.detach(successorClient)
            successor.finish()
        }
    }

    @Test fun pairingDeadlineUsesGrantExpiryAndNativeFiveMinuteMaximum() {
        assertEquals(1L, pairingDeadlineMillis(1.0, 1_000L))
        assertEquals(12_500L, pairingDeadlineMillis(13.5, 1_000L))
        assertEquals(300_000L, pairingDeadlineMillis(999_999.0, 1_000L))
    }

    @Test fun elapsedPairingDeadlineFencesPersistenceWithoutDrainingTheMainLooper() {
        var elapsed = 99L
        val flight = MoonlightPairingFlight(100L) { elapsed }
        var persisted = false

        elapsed = 100L
        reject("cancelled") {
            flight.withActive { persisted = true }
        }

        assertFalse(persisted)
    }

    @Test fun pairingDeadlineIsRecheckedAfterFlightLockDelayBeforePersistence() {
        var elapsed = 99L
        val flight = MoonlightPairingFlight(100L) { elapsed }
        val holderEntered = CountDownLatch(1)
        val releaseHolder = CountDownLatch(1)
        val waiterStarted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val holder = executor.submit {
                flight.withActive {
                    holderEntered.countDown()
                    assertTrue(releaseHolder.await(2, TimeUnit.SECONDS))
                }
            }
            assertTrue(holderEntered.await(2, TimeUnit.SECONDS))
            var persisted = false
            val waiter = executor.submit<Result<Unit>> {
                waiterStarted.countDown()
                runCatching { flight.withActive { persisted = true } }
            }
            assertTrue(waiterStarted.await(2, TimeUnit.SECONDS))

            elapsed = 100L
            releaseHolder.countDown()

            holder.get(2, TimeUnit.SECONDS)
            val failure = waiter.get(2, TimeUnit.SECONDS).exceptionOrNull()
            assertEquals("cancelled", (failure as MoonlightRuntimeFailure).code)
            assertFalse(persisted)
        } finally {
            releaseHolder.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun cancelledPairingFlightCannotCommitPrivateRegistration() {
        val flight = MoonlightPairingFlight()
        var persisted = false
        flight.cancel()
        reject("cancelled") {
            flight.withActive { persisted = true }
        }
        assertFalse(persisted)
    }

    @Test fun renderedFrameAndAcceptedPcmWitnessesAreExactBoundedAndLeaseFenced() {
        fun activity() = Robolectric.buildActivity(Activity::class.java).setup().visible().get().also {
            it.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        }
        val observations = mutableListOf<MoonlightLeaseObservation>()
        val first = MoonlightForegroundLeaseRegistry.issue(launchSpec(), observations::add)
        MoonlightForegroundLeaseRegistry.claim(first.token, activity())

        assertEquals(null, MoonlightForegroundLeaseRegistry.videoFrameRendered(first.token))
        assertEquals(null, MoonlightForegroundLeaseRegistry.audioPcmWritten(first.token, 8, 8))
        MoonlightForegroundLeaseRegistry.connectionStarted(first.token)
        shadowOf(Looper.getMainLooper()).idle()
        repeat(10) { MoonlightForegroundLeaseRegistry.videoFrameRendered(first.token) }
        assertEquals(null, MoonlightForegroundLeaseRegistry.audioPcmWritten(first.token, 8, 0))
        assertEquals(null, MoonlightForegroundLeaseRegistry.audioPcmWritten(first.token, 8, 4))
        repeat(10) { MoonlightForegroundLeaseRegistry.audioPcmWritten(first.token, 8, 8) }
        assertEquals(
            MoonlightOutputWitnessSnapshot(first.sessionId, first.epoch, 1, 1),
            MoonlightForegroundLeaseRegistry.outputWitnessSnapshot(first.token),
        )
        assertEquals(listOf("connectionStarted"), observations.map { it.observationKind })

        MoonlightForegroundLeaseRegistry.retireSession(first.sessionId, first.epoch)
        assertEquals(null, MoonlightForegroundLeaseRegistry.videoFrameRendered(first.token))
        assertEquals(null, MoonlightForegroundLeaseRegistry.audioPcmWritten(first.token, 8, 8))
        MoonlightForegroundLeaseRegistry.connectionStopStarted(first.token)
        MoonlightForegroundLeaseRegistry.connectionStopped(first.token)

        val successor = MoonlightForegroundLeaseRegistry.issue(
            launchSpec().copy(sessionId = ids.getValue(9), epoch = 2),
        )
        assertEquals(null, MoonlightForegroundLeaseRegistry.videoFrameRendered(first.token))
        assertEquals(null, MoonlightForegroundLeaseRegistry.audioPcmWritten(first.token, 8, 8))
        assertEquals(MoonlightOutputWitnessSnapshot(successor.sessionId, successor.epoch, 0, 0),
            MoonlightForegroundLeaseRegistry.outputWitnessSnapshot(successor.token))
    }

    @Test fun catalogDigestMatchesCoreCanonicalJsonIncludingEmptyCatalog() {
        assertEquals(
            "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
            canonicalCatalogDigest(emptyList()),
        )
        assertEquals(
            "ac2abbc17b76575f2cbbe839d5a722717a071faa7f16493afd2523f27f31baa9",
            canonicalCatalogDigest(listOf(
                MoonlightObservedApp(0, "6".repeat(32), 4, "Masaüstü", 42, true),
            )),
        )
        assertEquals(256, requireBoundedCatalog((0 until 256).toList(), 256).size)
        reject("provider_unavailable") { requireBoundedCatalog((0..256).toList(), 256) }
    }

    @Test fun pairedHostObservationContainsOnlyUpstreamReportedCodecFacts() {
        val observation = org.json.JSONObject(pairing().observationJson)
        assertEquals(setOf("h264"), observation.getJSONArray("codecs").let { codecs ->
            (0 until codecs.length()).map(codecs::getString).toSet()
        })
        assertFalse(observation.has("maxWidth"))
        assertFalse(observation.has("maxHeight"))
        assertFalse(observation.has("maxFps"))
    }

    @Test fun decoderRequestCandidatesAreBoundedAlignedAndNeverFabricateDisplayFacts() {
        assertEquals(1918, alignedDown(1919, 2))
        val candidates = candidateDimensions(3840, 2160, 16, 8)
        assertEquals(3840 to 2160, candidates.first())
        assertTrue(candidates.all { (width, height) -> width % 16 == 0 && height % 8 == 0 })
        assertEquals(emptyList<Pair<Int, Int>>(), candidateDimensions(16384, 2160, 16, 8))
    }

    @Test fun networkObservationBindsActualNetworkAndDestinationSpecificRoute() {
        assertEquals("local", classifyReachability(listOf(24, 0), 32, true, false))
        assertEquals("remote", classifyReachability(listOf(0), 32, true, true))
        assertEquals("unavailable", classifyReachability(listOf(0), 32, true, false))
        assertEquals("unavailable", classifyReachability(emptyList(), 32, true, true))
        val first = networkIdentity(41, listOf(1), "local", false, "a".repeat(64))
        val second = networkIdentity(42, listOf(1), "local", false, "a".repeat(64))
        assertNotEquals(first, second)
        assertEquals("192.0.2.1", parseNumericAddress("192.0.2.1")?.hostAddress)
        assertTrue(parseNumericAddress("2001:db8::1")?.hostAddress?.contains(':') == true)
        assertEquals(null, parseNumericAddress("sunshine.example.invalid"))
        assertEquals(null, parseNumericAddress("999.1.1.1"))
    }

    @Test fun uiDiscoveryTimeoutIsAcceptedBindTimeoutIsBoundedAndCandidatesAreCapped() {
        val application = RuntimeEnvironment.getApplication() as Context
        fun context(bindResult: Boolean) = object : ContextWrapper(application) {
            override fun bindService(intent: Intent, connection: ServiceConnection, flags: Int): Boolean = bindResult
            override fun unbindService(connection: ServiceConnection) = Unit
        }
        val immediate = AtomicReference<String?>()
        MoonlightMdnsDiscovery(context(false)).discover(15_000) { outcome ->
            immediate.set(outcome.exceptionOrNull()?.let { (it as MoonlightRuntimeFailure).code })
        }
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("provider_unavailable", immediate.get())

        val timed = AtomicReference<String?>()
        MoonlightMdnsDiscovery(context(true)).discover(1_000) { outcome ->
            timed.set(outcome.exceptionOrNull()?.let { (it as MoonlightRuntimeFailure).code })
        }
        shadowOf(Looper.getMainLooper()).idleFor(1_001, TimeUnit.MILLISECONDS)
        assertEquals("provider_unavailable", timed.get())

        val found = linkedMapOf<String, MoonlightDiscoveredEndpoint>()
        repeat(100) { offset ->
            addDiscoveredEndpoint(found, MoonlightDiscoveredEndpoint("Host $offset", "192.0.2.${offset + 1}", 47989), 64)
        }
        assertEquals(64, found.size)
    }

    @Test fun scopeSeparatesCredentialIdentityDatabaseAndPreferenceNamespaces() {
        val context = RuntimeEnvironment.getApplication() as Context
        val first = MoonlightScopedContext.create(context, scope(1))
        val second = MoonlightScopedContext.create(context, scope(2))
        first.openFileOutput("client.key", Context.MODE_PRIVATE).use { it.write(byteArrayOf(1, 2, 3)) }
        second.openFileOutput("client.key", Context.MODE_PRIVATE).use { it.write(byteArrayOf(4, 5, 6)) }
        first.getSharedPreferences("PreferenceConfiguration", Context.MODE_PRIVATE)
            .edit().putString("codec", "h264").commit()
        second.getSharedPreferences("PreferenceConfiguration", Context.MODE_PRIVATE)
            .edit().putString("codec", "av1").commit()
        assertNotEquals(first.filesDir, second.filesDir)
        assertEquals(listOf<Byte>(1, 2, 3), first.openFileInput("client.key").readBytes().toList())
        assertEquals(listOf<Byte>(4, 5, 6), second.openFileInput("client.key").readBytes().toList())
        assertEquals("h264", first.getSharedPreferences("PreferenceConfiguration", 0).getString("codec", null))
        assertEquals("av1", second.getSharedPreferences("PreferenceConfiguration", 0).getString("codec", null))
        reject("invalid_file_name") { first.openFileOutput("../client.key", Context.MODE_PRIVATE) }
    }

    @Test fun pinRequiredPolicyNeedsConfiguredFreshUnlockForConfigureAndExecute() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val runtime = MoonlightEmbeddedRuntime(activity)
        val unlocked = authority().copy(scope = scope(5), pinConfigured = true, pinUnlocked = true)
        val locked = unlocked.copy(pinUnlocked = false)
        assertNotEquals(unlocked.fingerprint, locked.fingerprint)

        runtime.bindAuthority(locked)
        reject("pin_required") { runtime.configurePolicy(locked, 0, policy()) }
        runtime.bindAuthority(unlocked)
        assertEquals(1L, runtime.configurePolicy(unlocked, 0, policy()).policyRevision)
        runtime.bindAuthority(locked)
        reject("pin_required") {
            runtime.executeCommand(
                locked, ids.getValue(1), ids.getValue(2), 1, ids.getValue(3), "stream",
                ids.getValue(4),
            ) { fail("locked PIN must not dispatch") }
        }
        runtime.close()
    }

    @Test fun durableDispatchingAndUnknownPairingAreNeverReservedForRedispatch() {
        val directory = File(temporary.root, "journal").apply { mkdirs() }
        val journal = MoonlightOperationJournal(directory)
        val prepared = operation()
        assertEquals(MoonlightOperationState.PREPARED, journal.reserve(prepared).state)
        journal.transition(ids.getValue(1), MoonlightOperationState.PREPARED, MoonlightOperationState.DISPATCHING, 0)
        val restarted = MoonlightOperationJournal(directory)
        assertEquals(MoonlightOperationState.DISPATCHING, restarted.reserve(prepared).state)
        restarted.transition(
            ids.getValue(1), MoonlightOperationState.DISPATCHING, MoonlightOperationState.UNKNOWN, 9,
            "{\"status\":\"unknown\"}",
        )
        assertEquals(MoonlightOperationState.UNKNOWN, MoonlightOperationJournal(directory).reserve(prepared).state)
        reject("invalid_receipt") { restarted.reserve(prepared.copy(fingerprint = "f".repeat(64))) }
        reject("invalid_receipt") { restarted.reserve(prepared.copy(requestId = ids.getValue(2))) }
        reject("quarantined") {
            restarted.reserve(prepared.copy(requestId = ids.getValue(2), operationId = ids.getValue(5)))
        }
    }

    @Test fun expiredKnownReceiptsArePrunedButUnknownAndLegacyEvidenceRemainQuarantined() {
        val directory = File(temporary.root, "retention-journal").apply { mkdirs() }
        var now = 1_000_000L
        val journal = MoonlightOperationJournal(directory) { now }
        val known = operation().copy(expiresAtEpochMillis = now + 1_000)
        journal.reserve(known)
        journal.transition(
            known.requestId, MoonlightOperationState.PREPARED,
            MoonlightOperationState.CONFIRMED, 1, "{}",
        )
        val uncertain = operation().copy(
            requestId = ids.getValue(2), operationId = ids.getValue(4), kind = "catalog",
            subject = ids.getValue(5), expiresAtEpochMillis = now + 1_000,
        )
        journal.reserve(uncertain)
        journal.transition(
            uncertain.requestId, MoonlightOperationState.PREPARED,
            MoonlightOperationState.DISPATCHING, 0,
        )
        journal.transition(
            uncertain.requestId, MoonlightOperationState.DISPATCHING,
            MoonlightOperationState.UNKNOWN, 0, "{}",
        )
        val legacyId = ids.getValue(6)
        File(directory, "$legacyId.json").writeText(org.json.JSONObject()
            .put("schemaVersion", 1)
            .put("requestId", legacyId)
            .put("operationId", ids.getValue(7))
            .put("kind", "revoke")
            .put("subject", ids.getValue(8))
            .put("fingerprint", "c".repeat(64))
            .put("authorityFingerprint", "d".repeat(64))
            .put("state", "confirmed")
            .put("readbackRevision", 1)
            .put("result", "{}")
            .toString())

        now += 301_001
        val trigger = operation().copy(
            requestId = ids.getValue(9), operationId = ids.getValue(10), kind = "revoke",
            subject = ids.getValue(11), expiresAtEpochMillis = 0,
        )
        journal.reserve(trigger)

        assertEquals(null, journal.read(known.requestId))
        assertEquals(MoonlightOperationState.UNKNOWN, journal.read(uncertain.requestId)?.state)
        assertEquals(0L, journal.read(legacyId)?.expiresAtEpochMillis)
        reject("authority_changed") { journal.reserve(known) }
    }

    @Test fun oneUseOperationCannotBeReservedAgainUnderANewRequestId() {
        val directory = File(temporary.root, "one-use-journal").apply { mkdirs() }
        val journal = MoonlightOperationJournal(directory)
        val first = operation()
        journal.reserve(first)
        journal.transition(
            first.requestId, MoonlightOperationState.PREPARED,
            MoonlightOperationState.CONFIRMED, 1, "{}",
        )
        assertEquals(MoonlightOperationState.CONFIRMED, journal.reserve(first).state)
        reject("invalid_receipt") {
            journal.reserve(first.copy(requestId = ids.getValue(2)))
        }
        assertEquals(first.requestId, journal.find(first.kind, first.operationId)?.requestId)
    }

    @Test fun twoStreamStopLifetimesUseOneDurableCausalReadbackSequence() {
        val directory = File(temporary.root, "readback-journal").apply { mkdirs() }
        val revisions = mutableListOf<Long>()
        fun runLifetime(sessionId: String, epoch: Long) {
            val journal = MoonlightOperationJournal(directory)
            val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get().also {
                it.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
            }
            val lease = MoonlightForegroundLeaseRegistry.issue(
                launchSpec().copy(sessionId = sessionId, epoch = epoch),
            ) { observation ->
                if (observation.observationKind in setOf("connectionStarted", "connectionTerminated")) {
                    revisions += journal.nextReadbackRevision()
                }
            }
            MoonlightForegroundLeaseRegistry.claim(lease.token, activity)
            MoonlightForegroundLeaseRegistry.connectionStarted(lease.token)
            shadowOf(Looper.getMainLooper()).idle()
            MoonlightForegroundLeaseRegistry.retireSession(sessionId, epoch)
            MoonlightForegroundLeaseRegistry.connectionTerminated(lease.token)
            shadowOf(Looper.getMainLooper()).idle()
        }
        runLifetime(ids.getValue(8), 1)
        runLifetime(ids.getValue(9), 2)
        assertEquals(listOf(1L, 2L, 3L, 4L), revisions)
        assertEquals("4", File(directory, "readback-counter").readText())
    }

    @Test fun embeddedGameSecuresWindowAndEveryStreamSurfaceBeforeAttachment() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        secureMoonlightWindow(activity)
        assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        val surface = RecordingSurfaceView(activity)
        val root = FrameLayout(activity).apply {
            addView(FrameLayout(activity).apply { addView(surface) })
        }
        secureMoonlightSurfaces(root)
        assertTrue(surface.secured)
        assertEquals(null, root.parent)
        requireLaunchDisplay(2, 2)
        reject("foreground_required") { requireLaunchDisplay(2, 0) }
    }

    @Test fun registrationMappingIsExactCasPrivateAndRestartSafe() {
        val storeFile = File(temporary.root, "registrations.json")
        val store = MoonlightRegistrationStore(storeFile)
        val pairing = pairing()
        store.savePairing(pairing)
        val registration = MoonlightCoreRegistration(
            nativeReceiptId = pairing.receiptId,
            registrationRevision = 1,
            hostId = ids.getValue(7),
            hostRevision = 2,
            pairingRevision = pairing.pairingRevision,
            catalogRevision = pairing.catalogRevision,
            apps = mapOf(0 to (ids.getValue(8) to 5L)),
        )
        store.saveRegistration(registration)
        val restarted = MoonlightRegistrationStore(storeFile)
        val resolved = restarted.resolve(ids.getValue(7), 2, 11, 12, ids.getValue(8), 5)
        assertEquals("upstream-private-uuid", resolved.first.upstreamHostUuid)
        assertEquals(42, resolved.second.upstreamAppId)
        assertFalse(storeFile.readText().contains("pairingGrant"))
        reject("stale_pairing") { restarted.resolve(ids.getValue(7), 3, 11, 12, ids.getValue(8), 5) }
        reject("stale_candidate") { restarted.resolve(ids.getValue(7), 2, 11, 12, ids.getValue(8), 6) }
    }

    @Test fun localRetirementClearsOnlyExactScopedComputerAndRegistration() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val expected = authorityWithClientInstance(
            authority().copy(scope = uniqueScope("local-retirement")),
            uniqueId("local-retirement-client"),
        )
        val runtime = MoonlightEmbeddedRuntime(activity)
        runtime.bindAuthority(expected)
        val scoped = MoonlightScopedContext.create(activity.applicationContext, expected.scope)
        val store = MoonlightRegistrationStore(File(scoped.noBackupFilesDir, "registrations.json"))
        val primary = uniquePairing("primary")
        val secondary = uniquePairing("secondary")
        val primaryHostId = uniqueId("primary-host")
        val secondaryHostId = uniqueId("secondary-host")
        seedRegistration(store, primary, primaryHostId, uniqueId("primary-app"))
        seedRegistration(store, secondary, secondaryHostId, uniqueId("secondary-app"))
        seedComputer(scoped, primary.upstreamHostUuid, "Primary")
        seedComputer(scoped, secondary.upstreamHostUuid, "Secondary")

        val otherScope = MoonlightScopedContext.create(
            activity.applicationContext, uniqueScope("other-retirement-scope"),
        )
        val otherUuid = "other-scope-private-uuid"
        seedComputer(otherScope, otherUuid, "Other scope")
        val identityBefore = IdentityManager(scoped).uniqueId

        val receipt = awaitRuntimeResult<MoonlightRevokeReceipt> { callback ->
            runtime.revoke(
                expected, uniqueId("revoke-request"), uniqueId("revocation"), primaryHostId,
                1, primary.pairingRevision, primary.catalogRevision, callback,
            )
        }.getOrThrow()
        assertEquals("local_cleared", receipt.status)
        assertNotNull(receipt.readbackRevision)
        assertEquals(null, readComputer(scoped, primary.upstreamHostUuid))
        assertNotNull(readComputer(scoped, secondary.upstreamHostUuid))
        assertNotNull(readComputer(otherScope, otherUuid))
        assertEquals(null, store.pairing(primary.receiptId))
        assertEquals(null, store.registration(primaryHostId))
        assertNotNull(store.pairing(secondary.receiptId))
        assertNotNull(store.registration(secondaryHostId))
        assertEquals(identityBefore, IdentityManager(scoped).uniqueId)
        runtime.close()
    }

    @Test fun failedLocalRetirementStaysUnknownAndExactReplayDoesNotRunCleanupAgain() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val expected = authorityWithClientInstance(
            authority().copy(scope = uniqueScope("failed-local-retirement")),
            uniqueId("failed-local-retirement-client"),
        )
        val attempts = AtomicInteger()
        val runtime = MoonlightEmbeddedRuntime(
            activity,
            localRetirementAfterRegistrationFence = {
                attempts.incrementAndGet()
                throw MoonlightRuntimeFailure("unknown_effect")
            },
        )
        runtime.bindAuthority(expected)
        val scoped = MoonlightScopedContext.create(activity.applicationContext, expected.scope)
        val store = MoonlightRegistrationStore(File(scoped.noBackupFilesDir, "registrations.json"))
        val pairing = uniquePairing("failed")
        val hostId = uniqueId("failed-host")
        seedRegistration(store, pairing, hostId, uniqueId("failed-app"))
        seedComputer(scoped, pairing.upstreamHostUuid, "Failed")
        val requestId = uniqueId("failed-request")
        val revocationId = uniqueId("failed-revocation")

        fun revoke() = awaitRuntimeResult<MoonlightRevokeReceipt> { callback ->
            runtime.revoke(
                expected, requestId, revocationId, hostId,
                1, pairing.pairingRevision, pairing.catalogRevision, callback,
            )
        }.getOrThrow()

        assertEquals("unknown", revoke().status)
        assertEquals(1, attempts.get())
        assertNotNull(readComputer(scoped, pairing.upstreamHostUuid))
        assertEquals(null, store.pairing(pairing.receiptId))
        assertEquals(null, store.registration(hostId))
        reject("quarantined") {
            runtime.resolveHostBinding(expected, hostId, 1, pairing.pairingRevision, pairing.catalogRevision)
        }
        assertEquals("unknown", revoke().status)
        assertEquals(1, attempts.get())
        assertEquals(
            MoonlightOperationState.UNKNOWN,
            MoonlightOperationJournal(File(scoped.noBackupFilesDir, "journal")).read(requestId)?.state,
        )
        runtime.close()
    }

    @Test fun localRetirementFencesConcurrentSuccessorRegistrationBeforeStorageCleanup() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val expected = authorityWithClientInstance(
            authority().copy(scope = uniqueScope("retirement-fence")),
            uniqueId("retirement-fence-client"),
        )
        val scoped = MoonlightScopedContext.create(activity.applicationContext, expected.scope)
        val store = MoonlightRegistrationStore(File(scoped.noBackupFilesDir, "registrations.json"))
        val current = uniquePairing("retirement-current")
        val successor = uniquePairing("retirement-successor")
        val hostId = uniqueId("retirement-host")
        seedRegistration(store, current, hostId, uniqueId("retirement-current-app"))
        store.savePairing(successor)
        seedComputer(scoped, current.upstreamHostUuid, "Retiring")
        val successorRegistration = MoonlightCoreRegistration(
            successor.receiptId, 2, hostId, 2,
            successor.pairingRevision, successor.catalogRevision,
            mapOf(0 to (uniqueId("retirement-successor-app") to 1L)),
        )
        val blocked = AtomicInteger()
        lateinit var runtime: MoonlightEmbeddedRuntime
        runtime = MoonlightEmbeddedRuntime(
            activity,
            localRetirementAfterRegistrationFence = {
                reject("quarantined") { runtime.commitRegistration(expected, successorRegistration) }
                blocked.incrementAndGet()
            },
        )
        runtime.bindAuthority(expected)

        val receipt = awaitRuntimeResult<MoonlightRevokeReceipt> { callback ->
            runtime.revoke(
                expected, uniqueId("retirement-fence-request"), uniqueId("retirement-fence-operation"),
                hostId, 1, current.pairingRevision, current.catalogRevision, callback,
            )
        }.getOrThrow()

        assertEquals("local_cleared", receipt.status)
        assertEquals(1, blocked.get())
        assertEquals(null, store.registration(hostId))
        assertNotNull(store.pairing(successor.receiptId))
        assertEquals(null, readComputer(scoped, current.upstreamHostUuid))
        runtime.close()
    }

    @Test fun localRetirementReleasesVolatileFenceWhenDispatchCannotStart() {
        fun runFailure(beforeSubmission: Boolean) {
            val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
            val expected = authorityWithClientInstance(
                authority().copy(scope = uniqueScope(if (beforeSubmission) "submit-failure" else "dispatch-failure")),
                uniqueId(if (beforeSubmission) "submit-failure-client" else "dispatch-failure-client"),
            )
            val scoped = MoonlightScopedContext.create(activity.applicationContext, expected.scope)
            val store = MoonlightRegistrationStore(File(scoped.noBackupFilesDir, "registrations.json"))
            val pairing = uniquePairing(if (beforeSubmission) "submit-failure" else "dispatch-failure")
            val hostId = uniqueId(if (beforeSubmission) "submit-failure-host" else "dispatch-failure-host")
            val requestId = uniqueId(if (beforeSubmission) "submit-failure-request" else "dispatch-failure-request")
            seedRegistration(store, pairing, hostId, uniqueId("dispatch-failure-app"))
            seedComputer(scoped, pairing.upstreamHostUuid, "Dispatch failure")
            lateinit var runtime: MoonlightEmbeddedRuntime
            val beforeDispatch: (() -> Unit)? = if (beforeSubmission) null else ({
                throw MoonlightRuntimeFailure("unknown_effect")
            })
            val beforeSubmissionHook: (() -> Unit)? = if (!beforeSubmission) null else ({
                val field = MoonlightEmbeddedRuntime::class.java.getDeclaredField("executor")
                    .apply { isAccessible = true }
                (field.get(runtime) as ExecutorService).shutdownNow()
            })
            runtime = MoonlightEmbeddedRuntime(
                activity,
                localRetirementBeforeDispatch = beforeDispatch,
                localRetirementBeforeSubmission = beforeSubmissionHook,
            )
            runtime.bindAuthority(expected)

            val failure = runCatching {
                runtime.revoke(
                    expected, requestId, uniqueId("dispatch-failure-operation"), hostId,
                    1, pairing.pairingRevision, pairing.catalogRevision,
                ) { fail("dispatch failure must not invoke callback") }
            }.exceptionOrNull()
            assertNotNull(failure)
            val journal = MoonlightOperationJournal(File(scoped.noBackupFilesDir, "journal"))
            assertEquals(
                if (beforeSubmission) MoonlightOperationState.DISPATCHING else MoonlightOperationState.PREPARED,
                journal.read(requestId)?.state,
            )
            val successor = expected.copy(routeRevision = expected.routeRevision + 1)
            assertNotNull(runtime.bindAuthority(successor))
            runtime.close()
        }

        runFailure(false)
        runFailure(true)
    }

    @Test fun ownedGameUsesActualInputIdleAndHardSessionDeadlines() {
        fun activity() = Robolectric.buildActivity(Activity::class.java).setup().visible().get().also {
            it.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        }
        val firstActivity = activity()
        val idleLease = MoonlightForegroundLeaseRegistry.issue(
            launchSpec().copy(maximumLifetimeMillis = 1_000, maximumIdleMillis = 100),
        )
        MoonlightForegroundLeaseRegistry.claim(idleLease.token, firstActivity)
        repeat(1_000) { MoonlightForegroundLeaseRegistry.inputActivity(idleLease.token) }
        assertEquals(1, MoonlightForegroundLeaseRegistry.pendingIdleTimerCountForTest())
        shadowOf(Looper.getMainLooper()).idleFor(75, TimeUnit.MILLISECONDS)
        MoonlightForegroundLeaseRegistry.inputActivity(idleLease.token)
        shadowOf(Looper.getMainLooper()).idleFor(75, TimeUnit.MILLISECONDS)
        assertEquals(MoonlightLeaseState.GAME_VISIBLE,
            MoonlightForegroundLeaseRegistry.snapshot(idleLease.token).state)
        shadowOf(Looper.getMainLooper()).idleFor(30, TimeUnit.MILLISECONDS)
        assertEquals(MoonlightLeaseState.RETIRING,
            MoonlightForegroundLeaseRegistry.snapshot(idleLease.token).state)
        assertTrue(firstActivity.isFinishing)
        MoonlightForegroundLeaseRegistry.connectionTerminated(idleLease.token)

        val hardActivity = activity()
        val hardLease = MoonlightForegroundLeaseRegistry.issue(
            launchSpec().copy(sessionId = ids.getValue(9), epoch = 2,
                maximumLifetimeMillis = 150, maximumIdleMillis = 1_000),
        )
        MoonlightForegroundLeaseRegistry.claim(hardLease.token, hardActivity)
        shadowOf(Looper.getMainLooper()).idleFor(100, TimeUnit.MILLISECONDS)
        MoonlightForegroundLeaseRegistry.inputActivity(hardLease.token)
        shadowOf(Looper.getMainLooper()).idleFor(60, TimeUnit.MILLISECONDS)
        assertEquals(MoonlightLeaseState.RETIRING,
            MoonlightForegroundLeaseRegistry.snapshot(hardLease.token).state)
        assertTrue(hardActivity.isFinishing)
    }

    @Test fun repeatedCatalogMappingsReplacePrivatePairingAndRevokeLeavesNoOrphan() {
        val storeFile = File(temporary.root, "catalog-registrations.json")
        val store = MoonlightRegistrationStore(storeFile)
        var latest = pairing()
        repeat(80) { offset ->
            latest = latest.copy(
                receiptId = (offset + 100).toString(16).padStart(32, '0'),
                catalogRevision = offset + 1L,
            )
            store.savePairing(latest)
            store.saveRegistration(MoonlightCoreRegistration(
                nativeReceiptId = latest.receiptId,
                registrationRevision = offset + 1L,
                hostId = ids.getValue(7),
                hostRevision = 2,
                pairingRevision = latest.pairingRevision,
                catalogRevision = latest.catalogRevision,
                apps = mapOf(0 to (ids.getValue(8) to 5L)),
            ))
        }
        assertEquals(latest.receiptId, store.registration(ids.getValue(7))?.nativeReceiptId)
        assertNotNull(store.pairing(latest.receiptId))
        store.deletePairing(latest.receiptId)
        assertEquals(null, store.registration(ids.getValue(7)))
        assertEquals(null, store.pairing(latest.receiptId))
        assertEquals(0, org.json.JSONObject(storeFile.readText()).getJSONArray("pairings").length())
    }

    @Test fun streamPolicyHasNoDefaultUsesExactCasAndPersistsSafeRevision() {
        val file = File(temporary.root, "policy.json")
        val store = MoonlightPolicyStore(file, scope(1))
        assertEquals(null, store.current())
        val requested = policy()
        val first = store.configure(0, requested)
        assertEquals(1, first.policyRevision)
        assertTrue(first.policyRevision <= MAX_JS_REVISION)
        assertEquals(first, MoonlightPolicyStore(file, scope(1)).current())
        reject("authority_changed") { store.configure(0, requested) }
        val second = store.configure(1, requested.copy(maxFramesPerSecond = 60))
        assertEquals(2, second.policyRevision)
        assertEquals(60, second.maxFramesPerSecond)
    }

    @Test fun foregroundLeaseAllowsOnlyExactOwnedGameAndFencesReplacement() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        activity.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        val spec = launchSpec()
        val lease = MoonlightForegroundLeaseRegistry.issue(spec)
        assertEquals(MoonlightLeaseState.TRANSFER_PENDING, lease.state)
        assertEquals(spec, MoonlightForegroundLeaseRegistry.resolveForLaunch(lease.token))
        assertEquals(MoonlightLeaseState.GAME_VISIBLE,
            MoonlightForegroundLeaseRegistry.claim(lease.token, activity).state)
        assertNotNull(MoonlightForegroundLeaseRegistry.ownedSnapshot(
            spec.authority.authorityId, spec.authority.epoch, spec.sessionId, spec.epoch,
        ))
        assertEquals(null, MoonlightForegroundLeaseRegistry.ownedSnapshot(
            spec.authority.authorityId, spec.authority.epoch, ids.getValue(9), spec.epoch,
        ))
        assertTrue(MoonlightForegroundLeaseRegistry.ownsHostCover(spec.authority.authorityId, spec.authority.epoch))
        reject("busy") { MoonlightForegroundLeaseRegistry.issue(spec.copy(sessionId = ids.getValue(9))) }
        reject("foreground_required") { MoonlightForegroundLeaseRegistry.resolveForLaunch(ids.getValue(10)) }
        assertEquals(MoonlightLeaseState.RETIRING,
            MoonlightForegroundLeaseRegistry.retire(spec.authority.authorityId, spec.authority.epoch)?.state)
        assertEquals(null, MoonlightForegroundLeaseRegistry.terminalWitnessSnapshot(lease.token))
        assertEquals(MoonlightLeaseState.RETIRED,
            MoonlightForegroundLeaseRegistry.connectionTerminated(lease.token)?.state)
        val terminal = requireNotNull(
            MoonlightForegroundLeaseRegistry.terminalWitnessSnapshot(lease.token),
        )
        assertEquals(spec.sessionId, terminal.sessionId)
        assertEquals(spec.epoch, terminal.epoch)
        assertEquals(MoonlightLeaseState.RETIRED, terminal.state)
        assertEquals("connectionTerminated", terminal.observationKind)
        assertEquals(null, MoonlightForegroundLeaseRegistry.ownedSnapshot(
            spec.authority.authorityId, spec.authority.epoch, spec.sessionId, spec.epoch,
        ))
        assertFalse(MoonlightForegroundLeaseRegistry.ownsHostCover(spec.authority.authorityId, spec.authority.epoch))
    }

    @Test fun lateOldGameCallbacksCannotChangeOrCrashSuccessorLease() {
        val firstActivity = Robolectric.buildActivity(Activity::class.java).setup().visible().get().also {
            it.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        }
        val first = MoonlightForegroundLeaseRegistry.issue(launchSpec())
        MoonlightForegroundLeaseRegistry.claim(first.token, firstActivity)
        MoonlightForegroundLeaseRegistry.connectionTerminated(first.token)
        val successorSpec = launchSpec().copy(sessionId = ids.getValue(9), epoch = 2)
        val successor = MoonlightForegroundLeaseRegistry.issue(successorSpec)
        assertEquals(null, MoonlightForegroundLeaseRegistry.connectionStarted(first.token))
        assertEquals(null, MoonlightForegroundLeaseRegistry.connectionTerminated(first.token))
        assertEquals(null, MoonlightForegroundLeaseRegistry.terminalWitnessSnapshot(successor.token))
        assertEquals(MoonlightLeaseState.TRANSFER_PENDING,
            MoonlightForegroundLeaseRegistry.snapshot(successor.token).state)
    }

    @Test fun relockAndUiDriftStillAllowExactOwnedSafetyStopAndFenceLateCallback() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get().also {
            it.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        }
        val bound = authority()
        val drifted = bound.copy(
            pinRevision = bound.pinRevision + 1,
            pinUnlocked = false,
            routeRevision = bound.routeRevision + 1,
            lifecycleRevision = bound.lifecycleRevision + 1,
            idleRevision = bound.idleRevision + 1,
            interactionRevision = bound.interactionRevision + 1,
        )
        assertTrue(bound.sameSafetyOwner(drifted))
        assertFalse(bound.sameSafetyOwner(drifted.copy(accountRevision = bound.accountRevision + 1)))

        val spec = launchSpec().copy(authority = bound)
        val lease = MoonlightForegroundLeaseRegistry.issue(spec)
        MoonlightForegroundLeaseRegistry.claim(lease.token, activity)
        MoonlightForegroundLeaseRegistry.connectionStarted(lease.token)
        assertEquals(lease.token, MoonlightForegroundLeaseRegistry.safetyStopSnapshot(
            bound.authorityId, bound.epoch, spec.sessionId, spec.epoch,
        )?.token)
        val terminal = AtomicReference<MoonlightLeaseObservation?>()
        MoonlightForegroundLeaseRegistry.observe(lease.token, terminal::set)
        assertEquals(MoonlightLeaseState.RETIRING,
            MoonlightForegroundLeaseRegistry.retireSession(spec.sessionId, spec.epoch)?.state)
        assertEquals(null, MoonlightForegroundLeaseRegistry.connectionStopped(lease.token))
        assertEquals(MoonlightLeaseState.RETIRING,
            MoonlightForegroundLeaseRegistry.connectionStopStarted(lease.token)?.state)
        assertEquals(MoonlightLeaseState.RETIRING,
            MoonlightForegroundLeaseRegistry.gameDestroyed(lease.token)?.state)
        MoonlightForegroundLeaseRegistry.connectionStopped(lease.token)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("connectionStopped", terminal.get()?.observationKind)

        val successor = MoonlightForegroundLeaseRegistry.issue(
            launchSpec().copy(sessionId = ids.getValue(9), epoch = 2),
        )
        assertEquals(null, MoonlightForegroundLeaseRegistry.connectionTerminated(lease.token))
        assertEquals(MoonlightLeaseState.TRANSFER_PENDING,
            MoonlightForegroundLeaseRegistry.snapshot(successor.token).state)
    }

    @Test fun retireNoMatchFailsClosedInsteadOfReturningSuccess() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val host = MoonlightMethodChannelHost(activity)
        val success = AtomicReference<Any?>()
        val error = AtomicReference<String?>()
        assertTrue(host.handle(
            "retire",
            mapOf("sessionId" to ids.getValue(8), "epoch" to 1),
            Consumer(success::set), Consumer(error::set),
        ))
        assertEquals(null, success.get())
        assertEquals("authority_changed", error.get())
        host.close()
    }

    @Test fun authorityRetirementResolvesLostBindingPersistsAndCannotFenceSuccessor() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val expected = authority()
        val requestId = ids.getValue(8)
        val runtime = MoonlightEmbeddedRuntime(activity)
        val binding = runtime.bindAuthority(expected)
        val retired = runtime.retireAuthority(expected, requestId, null, null)
        assertEquals(binding.first, retired.nativeBindingId)
        assertEquals(binding.second, retired.bindingRevision)
        assertEquals(expected.authorityId, retired.authorityId)
        assertEquals(expected.epoch, retired.authorityEpoch)
        assertEquals(retired, runtime.retireAuthority(expected, requestId, null, null))
        reject("authority_changed") { runtime.bindAuthority(expected) }

        val successor = authorityWithClientInstance(expected, ids.getValue(11))
        assertEquals(expected.scope, successor.scope)
        assertEquals(expected.routeRevision, successor.routeRevision)
        assertNotEquals(expected.authorityId, successor.authorityId)
        assertNotEquals(expected.fingerprint, successor.fingerprint)
        val successorBinding = runtime.bindAuthority(successor)
        assertEquals(retired, runtime.retireAuthority(expected, requestId, null, null))
        assertEquals(successorBinding, runtime.bindAuthority(successor))
        reject("authority_changed") {
            runtime.retireAuthority(expected, ids.getValue(9), null, null)
        }
        reject("authority_changed") {
            runtime.retireAuthority(
                successor, ids.getValue(10), retired.nativeBindingId, retired.bindingRevision,
            )
        }
        runtime.close()

        val restarted = MoonlightEmbeddedRuntime(activity)
        assertEquals(retired, restarted.retireAuthority(expected, requestId, null, null))
        reject("authority_changed") { restarted.bindAuthority(expected) }
        restarted.close()
    }

    @Test fun retirementFencesLateDiscoveryAndMethodChannelReturnsExactBindingReceipt() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val discovery = ControlledDiscovery()
        val expected = authority().copy(scope = scope(6))
        val runtime = MoonlightEmbeddedRuntime(activity, discovery = discovery)
        val binding = runtime.bindAuthority(expected)
        val discoveryResult = AtomicReference<Result<List<MoonlightCandidate>>?>()
        runtime.discover(expected, ids.getValue(8), 15_000, discoveryResult::set)
        val retired = runtime.retireAuthority(expected, ids.getValue(9), null, null)
        discovery.complete(emptyList())
        repeat(20) {
            shadowOf(Looper.getMainLooper()).idle()
            if (discoveryResult.get() != null) return@repeat
            Thread.sleep(10)
        }
        assertEquals(
            "authority_changed",
            (discoveryResult.get()?.exceptionOrNull() as? MoonlightRuntimeFailure)?.code,
        )
        assertEquals(binding.first, retired.nativeBindingId)
        runtime.close()

        val host = MoonlightMethodChannelHost(activity)
        val wire = wireAuthority().toMutableMap().apply {
            this["accountId"] = ids.getValue(7)
            this["familyId"] = ids.getValue(8)
        }
        val boundAuthority = authorityFromWire(wire)
        // beginPairing binds before its asynchronous callback. The runtime-level
        // regression above proves that exact lost-callback window; this call
        // verifies the nullable wire and durable public retirement receipt.
        val beginError = AtomicReference<String?>()
        host.setResumed(true)
        host.setWindowFocused(true)
        host.handle("beginPairingV2", mapOf(
            "schemaVersion" to 2, "requestId" to ids.getValue(10),
            "authority" to wire, "timeoutMs" to 1_000,
        ), Consumer { }, Consumer(beginError::set))
        val success = AtomicReference<Any?>()
        val error = AtomicReference<String?>()
        host.handle("retireAuthorityV2", mapOf(
            "schemaVersion" to 2, "requestId" to ids.getValue(11),
            "authority" to wire, "nativeBindingId" to null, "bindingRevision" to null,
        ), Consumer(success::set), Consumer(error::set))
        assertEquals(null, error.get())
        val receipt = success.get() as Map<*, *>
        assertEquals("retired", receipt["state"])
        assertEquals(boundAuthority.authorityId, receipt["authorityId"])
        assertTrue((receipt["nativeBindingId"] as String).matches(Regex("^[0-9a-f]{32}$")))
        assertTrue((receipt["bindingRevision"] as Long) > 0)
        host.close()
    }

    @Test fun authorityRetirementFencesEvenWhenDurableReceiptWriteFails() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val expected = authority().copy(scope = scope(7))
        val failedStore = object : MoonlightAuthorityRetirementPersistence {
            override fun read(requestId: String) = null
            override fun containsAuthority(authorityFingerprint: String) = false
            override fun save(receipt: MoonlightAuthorityRetirementReceipt) {
                throw MoonlightRuntimeFailure("unknown_effect")
            }
        }
        val runtime = MoonlightEmbeddedRuntime(activity, retirementStoreFactory = { failedStore })
        runtime.bindAuthority(expected)
        reject("unknown_effect") {
            runtime.retireAuthority(expected, ids.getValue(8), null, null)
        }
        reject("authority_changed") { runtime.bindAuthority(expected) }
        reject("unknown_effect") {
            runtime.retireAuthority(expected, ids.getValue(8), null, null)
        }
        runtime.close()
    }

    @Test fun retirementFencesDiscoveryAtWorkerCommitAndQueuedMainDelivery() {
        fun runRace(blockCommit: Boolean) {
            val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
            val discovery = ControlledDiscovery()
            val reached = CountDownLatch(1)
            val release = CountDownLatch(1)
            val hook = {
                reached.countDown()
                assertTrue(release.await(2, TimeUnit.SECONDS))
            }
            val expected = authority().copy(
                scope = if (blockCommit) scope(4) else scope(5),
                routeRevision = if (blockCommit) 81 else 82,
            )
            val runtime = MoonlightEmbeddedRuntime(
                activity,
                discovery = discovery,
                discoveryBeforeCommit = hook.takeIf { blockCommit },
                discoveryBeforeDelivery = hook.takeUnless { blockCommit },
            )
            runtime.bindAuthority(expected)
            val result = AtomicReference<Result<List<MoonlightCandidate>>?>()
            runtime.discover(expected, ids.getValue(if (blockCommit) 8 else 9), 15_000, result::set)
            discovery.complete(emptyList())
            assertTrue(reached.await(2, TimeUnit.SECONDS))
            runtime.retireAuthority(
                expected, ids.getValue(if (blockCommit) 10 else 11), null, null,
            )
            val successor = expected.copy(routeRevision = expected.routeRevision + 1)
            val successorBinding = runtime.bindAuthority(successor)
            release.countDown()
            repeat(40) {
                shadowOf(Looper.getMainLooper()).idle()
                if (result.get() == null) Thread.sleep(10)
            }
            assertEquals(
                "authority_changed",
                (result.get()?.exceptionOrNull() as? MoonlightRuntimeFailure)?.code,
            )
            assertEquals(successorBinding, runtime.bindAuthority(successor))
            runtime.close()
        }
        runRace(true)
        runRace(false)
    }

    @Test fun methodChannelReconcileIsReadOnlyExactAndAuthorityBound() {
        val context = RuntimeEnvironment.getApplication() as Context
        val wire = wireAuthority()
        val expected = authorityFromWire(wire)
        val scoped = MoonlightScopedContext.create(context, expected.scope)
        val journal = MoonlightOperationJournal(File(scoped.noBackupFilesDir, "journal"))
        val storedRequest = ids.getValue(10)
        val commandId = ids.getValue(11)
        val sessionId = ids.getValue(8)
        val result = org.json.JSONObject()
            .put("requestId", storedRequest).put("sessionId", sessionId).put("commandId", commandId)
            .put("state", "unknown").put("result", "unknown").put("observationKind", "unknown")
            .put("readbackRevision", org.json.JSONObject.NULL)
            .put("nativeReceiptDigest", org.json.JSONObject.NULL).toString()
        val prepared = MoonlightOperationRecord(
            storedRequest, commandId, "command", sessionId, "a".repeat(64), expected.fingerprint,
            MoonlightOperationState.PREPARED, 0, 0,
        )
        journal.reserve(prepared)
        journal.transition(storedRequest, MoonlightOperationState.PREPARED,
            MoonlightOperationState.DISPATCHING, 0)
        journal.transition(storedRequest, MoonlightOperationState.DISPATCHING,
            MoonlightOperationState.UNKNOWN, 0, result)

        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val host = MoonlightMethodChannelHost(activity)
        val success = AtomicReference<Any?>()
        val error = AtomicReference<String?>()
        val reconcileRequest = ids.getValue(12)
        assertTrue(host.handle("reconcileV2", mapOf(
            "schemaVersion" to 2, "requestId" to reconcileRequest, "authority" to wire,
            "operationKind" to "command", "operationId" to commandId,
        ), Consumer(success::set), Consumer(error::set)))
        assertEquals(null, error.get())
        val envelope = success.get() as Map<*, *>
        assertEquals(true, envelope["terminal"])
        val receipt = envelope["receipt"] as Map<*, *>
        assertEquals(reconcileRequest, receipt["requestId"])
        assertEquals(commandId, receipt["commandId"])
        assertEquals("unknown", receipt["state"])
        assertEquals(null, receipt["nativeReceiptDigest"])

        val revokeRequest = ids.getValue(5)
        val revocationId = ids.getValue(6)
        journal.reserve(MoonlightOperationRecord(
            revokeRequest, revocationId, "revoke", ids.getValue(4), "b".repeat(64),
            expected.fingerprint, MoonlightOperationState.PREPARED, 0, 0,
        ))
        journal.transition(
            revokeRequest, MoonlightOperationState.PREPARED,
            MoonlightOperationState.DISPATCHING, 0,
        )
        journal.transition(
            revokeRequest, MoonlightOperationState.DISPATCHING,
            MoonlightOperationState.UNKNOWN, 0,
            org.json.JSONObject().put("requestId", revokeRequest).put("status", "unknown")
                .put("readbackRevision", org.json.JSONObject.NULL).toString(),
        )
        success.set(null)
        error.set(null)
        val revokeReconcileRequest = ids.getValue(3)
        host.handle("reconcileV2", mapOf(
            "schemaVersion" to 2, "requestId" to revokeReconcileRequest, "authority" to wire,
            "operationKind" to "revoke", "operationId" to revocationId,
        ), Consumer(success::set), Consumer(error::set))
        assertEquals(null, error.get())
        val revokeEnvelope = success.get() as Map<*, *>
        val revokeReceipt = revokeEnvelope["receipt"] as Map<*, *>
        assertEquals("unknown", revokeReceipt["state"])
        assertEquals(null, revokeReceipt["readbackRevision"])
        assertEquals(null, revokeReceipt["nativeReceiptDigest"])

        val legacyRequest = uniqueId("legacy-revoked-request")
        val legacyOperation = uniqueId("legacy-revoked-operation")
        journal.reserve(MoonlightOperationRecord(
            legacyRequest, legacyOperation, "revoke", uniqueId("legacy-revoked-host"),
            "d".repeat(64), expected.fingerprint, MoonlightOperationState.PREPARED, 0, 0,
        ))
        journal.transition(
            legacyRequest, MoonlightOperationState.PREPARED,
            MoonlightOperationState.DISPATCHING, 0,
        )
        journal.transition(
            legacyRequest, MoonlightOperationState.DISPATCHING,
            MoonlightOperationState.REVOKED, 7,
            org.json.JSONObject().put("requestId", legacyRequest).put("status", "revoked")
                .put("readbackRevision", 7).toString(),
        )
        success.set(null)
        error.set(null)
        host.handle("reconcileV2", mapOf(
            "schemaVersion" to 2, "requestId" to uniqueId("legacy-reconcile"), "authority" to wire,
            "operationKind" to "revoke", "operationId" to legacyOperation,
        ), Consumer(success::set), Consumer(error::set))
        assertEquals(null, error.get())
        val legacyReceipt = (success.get() as Map<*, *>)["receipt"] as Map<*, *>
        assertEquals("local_cleared", legacyReceipt["state"])
        assertEquals(7L, legacyReceipt["readbackRevision"])
        assertNotNull(legacyReceipt["nativeReceiptDigest"])

        success.set(null)
        error.set(null)
        val foreign = wire.toMutableMap().apply { this["routeRevision"] = 99L }
        host.handle("reconcileV2", mapOf(
            "schemaVersion" to 2, "requestId" to ids.getValue(7), "authority" to foreign,
            "operationKind" to "command", "operationId" to commandId,
        ), Consumer(success::set), Consumer(error::set))
        assertEquals("authority_changed", error.get())
        assertEquals(null, success.get())
        host.close()
    }

    @Test fun v2SessionCommandAndRecoveryMethodsAreInstalledAndStrict() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val host = MoonlightMethodChannelHost(activity)
        val error = AtomicReference<String?>()
        assertTrue(host.handle("bindSessionV2", null, Consumer { fail("unexpected success") }, Consumer(error::set)))
        assertEquals("foreground_required", error.get())
        error.set(null)
        assertTrue(host.handle("executeV2", null, Consumer { fail("unexpected success") }, Consumer(error::set)))
        assertEquals("foreground_required", error.get())
        error.set(null)
        assertTrue(host.handle("foregroundLeaseV2", null,
            Consumer { fail("unexpected success") }, Consumer(error::set)))
        assertEquals("invalid_receipt", error.get())
        error.set(null)
        assertTrue(host.handle("pairingPromptV2", null,
            Consumer { fail("unexpected success") }, Consumer(error::set)))
        assertEquals("invalid_receipt", error.get())
        error.set(null)
        assertTrue(host.handle("reconcileV2", null, Consumer { fail("unexpected success") }, Consumer(error::set)))
        assertEquals("invalid_receipt", error.get())
        assertFalse(host.handle("notAV2Method", null, Consumer { fail("unexpected success") }, Consumer(error::set)))
        host.close()
    }

    @Test fun sharedV2ContractPinsNativeBoundsAndCausalObservations() {
        val contractPath = checkNotNull(System.getProperty("larenor.f60.contract")) {
            "missing larenor.f60.contract"
        }
        val contract = org.json.JSONObject(File(contractPath).readText())
        assertEquals(2, contract.getInt("schemaVersion"))
        assertEquals(256, contract.getJSONObject("limits").getInt("maxApps"))
        assertEquals(0, contract.getJSONObject("limits").getInt("minApps"))
        val observations = contract.getJSONObject("command").getJSONObject("observationKinds")
        assertEquals("connectionStarted", observations.getString("stream"))
        assertEquals("connectionStopped", observations.getString("stop"))
        assertEquals("connectionTerminated", observations.getString("remoteStop"))
        assertEquals("serverInfoOnline", observations.getString("wake"))
        assertEquals("currentGameMatched", observations.getString("launch"))
        assertEquals("unknown", observations.getString("unknown"))
        val unknown = MoonlightCommandReceipt(
            ids.getValue(1), ids.getValue(2), ids.getValue(3), "unknown", "unknown", "unknown", null, null,
        )
        assertEquals(null, unknown.readbackRevision)
        assertEquals(null, unknown.nativeReceiptDigest)
        assertEquals("hostAwake", MoonlightCommandReceipt(
            ids.getValue(1), ids.getValue(2), ids.getValue(3), "native_observed", "hostAwake",
            "serverInfoOnline", 1, "a".repeat(64),
        ).result)
        assertEquals("appRunning", MoonlightCommandReceipt(
            ids.getValue(1), ids.getValue(2), ids.getValue(3), "native_observed", "appRunning",
            "currentGameMatched", 2, "b".repeat(64),
        ).result)
        val selected = contract.getJSONObject("session").getJSONObject("open")
            .getJSONObject("request").getJSONObject("selectedQuality")
        assertEquals(setOf(
            "codec", "codecId", "codecRevision", "displayId", "displayRevision", "networkId",
            "networkRevision", "policyId", "policyRevision", "widthPixels", "heightPixels",
            "framesPerSecond", "bitrateKbps", "frameQueueDepth", "inputQueueDepth", "secureSurface",
        ), selected.keys().asSequence().toSet())
        val pairedHost = contract.getJSONObject("pairingIntent").getJSONObject("complete")
            .getJSONObject("request").getJSONObject("observation")
        assertFalse(pairedHost.has("maxWidth"))
        assertFalse(pairedHost.has("maxHeight"))
        assertFalse(pairedHost.has("maxFps"))
    }

    private fun scope(offset: Int) = MoonlightScope(
        ids.getValue(offset), ids.getValue(offset + 1), ids.getValue(offset + 2), ids.getValue(offset + 3),
    )

    private fun authority() = MoonlightAuthority(
        ids.getValue(1), 1, scope(2), ids.getValue(12), 2, 3, true, true, 4, 5, 6, 7,
    )

    private fun authorityWithClientInstance(
        value: MoonlightAuthority,
        clientInstanceId: String,
    ): MoonlightAuthority = value.copy(
        clientInstanceId = clientInstanceId,
        authorityId = sha256(
            "authority\u0000${value.scope.storageKey}\u0000$clientInstanceId".toByteArray(),
        ).hex().take(32),
        epoch = publicRevision(
            value.accountRevision.toString(), value.pinRevision.toString(),
            value.routeRevision.toString(), value.lifecycleRevision.toString(),
            value.idleRevision.toString(), value.interactionRevision.toString(),
            value.pinConfigured.toString(), value.pinUnlocked.toString(), clientInstanceId,
        ),
    )

    private fun wireAuthority(): Map<String, Any> = linkedMapOf(
        "coreId" to ids.getValue(1), "homeId" to ids.getValue(2),
        "accountId" to ids.getValue(3), "familyId" to ids.getValue(4),
        "accountRevision" to 2L, "pinRevision" to 3L, "routeRevision" to 4L,
        "pinConfigured" to true, "pinUnlocked" to true,
        "clientInstanceId" to ids.getValue(12),
        "lifecycleRevision" to 5L, "idleRevision" to 6L, "interactionRevision" to 7L,
    )

    private fun authorityFromWire(value: Map<String, Any>): MoonlightAuthority {
        val scope = MoonlightScope(
            value.getValue("coreId") as String, value.getValue("homeId") as String,
            value.getValue("accountId") as String, value.getValue("familyId") as String,
        )
        val revisions = listOf("accountRevision", "pinRevision", "routeRevision", "lifecycleRevision",
            "idleRevision", "interactionRevision").map { value.getValue(it) as Long }
        val pinConfigured = value.getValue("pinConfigured") as Boolean
        val pinUnlocked = value.getValue("pinUnlocked") as Boolean
        return MoonlightAuthority(
            sha256(
                "authority\u0000${scope.storageKey}\u0000${value.getValue("clientInstanceId")}".toByteArray(),
            ).hex().take(32),
            publicRevision(
                *(revisions.map(Long::toString) + pinConfigured.toString() + pinUnlocked.toString() +
                    (value.getValue("clientInstanceId") as String)).toTypedArray(),
            ), scope,
            value.getValue("clientInstanceId") as String,
            revisions[0], revisions[1], pinConfigured, pinUnlocked,
            revisions[2], revisions[3], revisions[4], revisions[5],
        )
    }

    private fun operation() = MoonlightOperationRecord(
        ids.getValue(1), ids.getValue(2), "pair", ids.getValue(3), "a".repeat(64), "b".repeat(64),
        MoonlightOperationState.PREPARED, 0, 0,
    )

    private fun pairing(): MoonlightNativePairing {
        val app = MoonlightObservedApp(0, ids.getValue(6), 4, "Desktop", 42, true)
        return MoonlightNativePairing(
            receiptId = ids.getValue(4), nativeBindingId = ids.getValue(5), bindingRevision = 3,
            hostObservationId = ids.getValue(9), upstreamHostUuid = "upstream-private-uuid",
            pairingRevision = 11, catalogRevision = 12, catalogDigest = "c".repeat(64),
            apps = listOf(app),
            observationJson = """{"schemaVersion":1,"codecs":["h264"]}""",
        )
    }

    private fun policy() = MoonlightStreamPolicy(
        ids.getValue(10), 1, setOf("h264", "hevc"), allowMetered = false, requirePin = true,
        maxWidth = 2560, maxHeight = 1440, maxFramesPerSecond = 120, maxBitrateKbps = 50_000,
        maximumIdleSeconds = 300, maximumSessionSeconds = 3_600,
        frameQueueDepth = 2, inputQueueDepth = 1,
    )

    private fun launchSpec() = MoonlightLaunchSpec(
        authority(), ids.getValue(8), 1, "d".repeat(64), "192.0.2.1", 47989, 47984,
        "Desktop", 42, "0123456789ABCDEF", "private-uuid", "Fixture", true,
        ByteArray(512) { 1 }, 0,
        60_000, 30_000,
    )

    private fun uniqueId(label: String): String = sha256(
        "${temporary.root.absolutePath}\u0000$label".toByteArray(),
    ).hex().take(32)

    private fun uniqueScope(label: String) = MoonlightScope(
        uniqueId("$label-core"), uniqueId("$label-home"),
        uniqueId("$label-account"), uniqueId("$label-family"),
    )

    private fun uniquePairing(label: String): MoonlightNativePairing = pairing().copy(
        receiptId = uniqueId("$label-receipt"),
        nativeBindingId = uniqueId("$label-binding"),
        hostObservationId = uniqueId("$label-host-observation"),
        upstreamHostUuid = "$label-private-uuid",
        apps = listOf(pairing().apps.single().copy(observationId = uniqueId("$label-observation"))),
    )

    private fun seedRegistration(
        store: MoonlightRegistrationStore,
        pairing: MoonlightNativePairing,
        hostId: String,
        appId: String,
    ) {
        store.savePairing(pairing)
        store.saveRegistration(MoonlightCoreRegistration(
            pairing.receiptId, 1, hostId, 1, pairing.pairingRevision,
            pairing.catalogRevision, mapOf(0 to (appId to 1L)),
        ))
    }

    private fun seedComputer(context: Context, uuid: String, name: String) {
        val details = ComputerDetails().apply {
            this.uuid = uuid
            this.name = name
            localAddress = ComputerDetails.AddressTuple("192.0.2.10", NvHTTP.DEFAULT_HTTP_PORT)
        }
        ComputerDatabaseManager(context).let { database ->
            try { assertTrue(database.updateComputer(details)) } finally { database.close() }
        }
    }

    private fun readComputer(context: Context, uuid: String): ComputerDetails? =
        ComputerDatabaseManager(context).let { database ->
            try { database.getComputerByUUID(uuid) } finally { database.close() }
        }

    private fun <T> awaitRuntimeResult(begin: ((Result<T>) -> Unit) -> Unit): Result<T> {
        val values = mutableListOf<Result<T>>()
        begin { value -> synchronized(values) { if (values.isEmpty()) values += value } }
        repeat(200) {
            shadowOf(Looper.getMainLooper()).idle()
            synchronized(values) { if (values.isNotEmpty()) return values.single() }
            Thread.sleep(10)
        }
        fail("runtime operation did not complete")
        throw AssertionError("unreachable")
    }

    private fun reject(code: String, action: () -> Unit) {
        try {
            action()
            fail("Expected $code")
        } catch (failure: MoonlightRuntimeFailure) {
            assertEquals(code, failure.code)
        } catch (failure: SecurityException) {
            assertEquals(code, failure.message)
        }
    }

    private class ControlledDiscovery : MoonlightDiscovery {
        private var callback: ((Result<List<MoonlightDiscoveredEndpoint>>) -> Unit)? = null

        override fun discover(
            timeoutMillis: Long,
            callback: (Result<List<MoonlightDiscoveredEndpoint>>) -> Unit,
        ) {
            this.callback = callback
        }

        fun complete(values: List<MoonlightDiscoveredEndpoint>) {
            checkNotNull(callback).invoke(Result.success(values))
        }
    }


    private class RecordingSurfaceView(context: Context) : SurfaceView(context) {
        var secured = false
        override fun setSecure(isSecure: Boolean) {
            secured = isSecure
            super.setSecure(isSecure)
        }
    }
}
