package com.ersingundem.larenor.game.moonlight

import android.os.SystemClock
import android.view.KeyEvent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.ersingundem.larenor.MainActivity
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Opt-in owned-provider acceptance. The host orchestrator owns a private,
 * pinned Sunshine process and exposes only a one-use PIN listener through adb
 * reverse. No host endpoint, credential, PIN, certificate, or launch token is
 * accepted as an instrumentation argument or emitted by this test.
 */
@RunWith(AndroidJUnit4::class)
class MoonlightOwnedSunshineStreamTest {
    @Test
    fun productionNsdPairCatalogLaunchStreamWitnessStopAndLocalRetirement() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue(
            "F60 owned Sunshine streaming is a named opt-in gate",
            arguments.getString(REQUIRED_ARGUMENT) == "required",
        )
        val nonce = requireNotNull(arguments.getString(PIN_NONCE_ARGUMENT)).also {
            require(NONCE.matches(it))
        }
        val expectedInstance = requireNotNull(arguments.getString(MDNS_INSTANCE_ARGUMENT)).also {
            require(MDNS_INSTANCE.matches(it))
        }
        val pinPort = requireNotNull(arguments.getString(PIN_PORT_ARGUMENT)).toInt().also {
            require(it == PIN_PORT)
        }
        idSeed = nonce

        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val activity = AtomicReference<MainActivity>()
            val runtime = AtomicReference<MoonlightEmbeddedRuntime>()
            scenario.onActivity { current ->
                activity.set(current)
                runtime.set(MoonlightEmbeddedRuntime(
                    current,
                    pinPresenter = LoopbackPinPresenter(nonce, pinPort),
                ))
            }
            val currentActivity = requireNotNull(activity.get())
            val value = requireNotNull(runtime.get())
            val authority = authority()
            try {
                value.bindAuthority(authority)
                val endpoints = discoverEndpoints(currentActivity)
                assertEquals(1, endpoints.size)
                assertEquals(expectedInstance, endpoints.single().name)
                assertEquals(SUNSHINE_PORT, endpoints.single().port)

                val candidate = awaitResult(DISCOVERY_DELIVERY_SECONDS) { callback ->
                    value.discover(authority, id("discover"), DISCOVERY_TIMEOUT_MILLIS, callback)
                }.single()
                assertEquals(OWNED_DISPLAY_NAME, candidate.displayName)
                assertEquals("awake", candidate.powerState)
                assertEquals("notPaired", candidate.pairState)

                val paired = awaitResult(PAIR_TIMEOUT_SECONDS) { callback ->
                    value.pair(
                        authority,
                        MoonlightPairAuthorization(
                            requestId = id("pair-request"),
                            pairingId = id("pairing"),
                            expectedPairingRevision = 1,
                            pairingGrant = id("pair-grant"),
                            expiresAtEpochSeconds = expiresAt(),
                        ),
                        candidate.candidateId,
                        candidate.candidateRevision,
                        callback,
                    )
                }
                assertEquals("paired", paired.status)
                val pairedHost = requireNotNull(paired.host)
                val initial = registration(
                    requireNotNull(paired.nativeObservationJson),
                    pairingRevision = pairedHost.pairingRevision,
                    registrationRevision = 1,
                    previousApps = emptyMap(),
                )
                value.commitRegistration(authority, initial.registration)

                val catalog = awaitResult(CATALOG_TIMEOUT_SECONDS) { callback ->
                    value.readCatalog(
                        authority,
                        MoonlightCatalogAuthorization(
                            requestId = id("catalog-request"),
                            catalogObservationId = id("catalog-observation"),
                            expectedObservationRevision = 1,
                            expectedCatalogRevision = initial.registration.catalogRevision,
                            catalogGrant = id("catalog-grant"),
                            expiresAtEpochSeconds = expiresAt(),
                        ),
                        initial.registration.hostId,
                        initial.registration.hostRevision,
                        initial.registration.pairingRevision,
                        callback,
                    )
                }
                assertEquals("observed", catalog.state)
                val refreshed = registration(
                    requireNotNull(catalog.nativeObservationJson),
                    pairingRevision = initial.registration.pairingRevision,
                    registrationRevision = 2,
                    previousApps = initial.appsByObservation,
                )
                value.commitRegistration(authority, refreshed.registration)
                val desktop = refreshed.apps.single { it.name == OWNED_APP_NAME }

                val facts = value.sessionCapabilities(
                    authority,
                    refreshed.registration.hostId,
                    refreshed.registration.hostRevision,
                    refreshed.registration.pairingRevision,
                    refreshed.registration.catalogRevision,
                    desktop.appId,
                    desktop.appRevision,
                )
                val display = requireNotNull(facts.display)
                val allowedCodecs = facts.decoders.asSequence()
                    .filter { it.supported && it.codec in pairedHost.codecs }
                    .map { it.codec }
                    .toSet()
                assertTrue("owned emulator has no Moonlight decoder", allowedCodecs.isNotEmpty())
                value.configurePolicy(
                    authority,
                    expectedRevision = 0,
                    requested = MoonlightStreamPolicy(
                        policyId = id("policy-placeholder"),
                        policyRevision = 1,
                        allowedCodecs = allowedCodecs,
                        allowMetered = true,
                        requirePin = true,
                        maxWidth = display.widthPixels,
                        maxHeight = display.heightPixels,
                        maxFramesPerSecond = display.maxRefreshRate,
                        maxBitrateKbps = OWNED_BITRATE_KBPS,
                        maximumIdleSeconds = MAXIMUM_IDLE_SECONDS,
                        maximumSessionSeconds = MAXIMUM_SESSION_SECONDS,
                        frameQueueDepth = 2,
                        inputQueueDepth = 1,
                    ),
                )
                val available = value.sessionCapabilities(
                    authority,
                    refreshed.registration.hostId,
                    refreshed.registration.hostRevision,
                    refreshed.registration.pairingRevision,
                    refreshed.registration.catalogRevision,
                    desktop.appId,
                    desktop.appRevision,
                )
                assertEquals(null, available.reason)
                assertEquals("available", available.availability)
                val quality = available.qualityOptions.firstOrNull { it.codec == "h264" }
                    ?: available.qualityOptions.first()
                val session = MoonlightBoundSession(
                    sessionId = id("session"),
                    sessionRevision = 1,
                    hostId = refreshed.registration.hostId,
                    hostRevision = refreshed.registration.hostRevision,
                    pairingRevision = refreshed.registration.pairingRevision,
                    catalogRevision = refreshed.registration.catalogRevision,
                    appId = desktop.appId,
                    appRevision = desktop.appRevision,
                    expiresAtEpochSeconds = expiresAt(MAXIMUM_SESSION_SECONDS.toLong()),
                    selectedQuality = quality.selected(),
                )
                value.bindSession(authority, session)

                val launched = command(value, authority, session, "launch", "launch")
                assertEquals("native_observed", launched.state)
                assertEquals("appRunning", launched.result)
                assertEquals("currentGameMatched", launched.observationKind)

                val streaming = command(value, authority, session, "stream", "stream")
                assertEquals("native_observed", streaming.state)
                assertEquals("streaming", streaming.result)
                assertEquals("connectionStarted", streaming.observationKind)

                val witness = awaitWitness(value, authority, session)
                assertEquals(1, witness.renderedFrameCount)
                assertEquals(1, witness.acceptedAudioWriteCount)
                dispatchOwnedKeyA()

                val stopped = command(value, authority, session, "stop", "stop")
                assertEquals("native_observed", stopped.state)
                assertEquals("stopped", stopped.result)
                assertEquals("connectionStopped", stopped.observationKind)
                value.retireExactSession(session.sessionId, session.sessionRevision)
                value.bindAuthority(authority)

                val scoped = MoonlightScopedContext.create(
                    currentActivity.applicationContext, authority.scope,
                )
                val registrationStore = MoonlightRegistrationStore(
                    java.io.File(scoped.noBackupFilesDir, "registrations.json"),
                )
                val privatePairing = requireNotNull(
                    registrationStore.pairing(refreshed.registration.nativeReceiptId),
                )

                val revoked = awaitResult(REVOKE_TIMEOUT_SECONDS) { callback ->
                    value.revoke(
                        authority,
                        requestId = id("revoke-request"),
                        revocationId = id("revocation"),
                        hostId = refreshed.registration.hostId,
                        expectedHostRevision = refreshed.registration.hostRevision,
                        expectedPairingRevision = refreshed.registration.pairingRevision,
                        expectedCatalogRevision = refreshed.registration.catalogRevision,
                        callback = callback,
                    )
                }
                assertEquals("local_cleared", revoked.status)
                assertNotNull(revoked.readbackRevision)
                assertEquals(null, registrationStore.pairing(privatePairing.receiptId))
                assertEquals(null, registrationStore.registration(refreshed.registration.hostId))
                assertEquals(null, com.limelight.computers.ComputerDatabaseManager(scoped).let { database ->
                    try { database.getComputerByUUID(privatePairing.upstreamHostUuid) } finally { database.close() }
                })
            } finally {
                value.close()
                MoonlightForegroundLeaseRegistry.clearForTest()
            }
        }
    }

    private fun discoverEndpoints(activity: MainActivity): List<MoonlightDiscoveredEndpoint> =
        awaitResult(DISCOVERY_DELIVERY_SECONDS) { callback ->
            MoonlightMdnsDiscovery(activity).discover(DISCOVERY_TIMEOUT_MILLIS, callback)
        }

    private fun command(
        runtime: MoonlightEmbeddedRuntime,
        authority: MoonlightAuthority,
        session: MoonlightBoundSession,
        intent: String,
        suffix: String,
    ): MoonlightCommandReceipt = awaitResult(COMMAND_TIMEOUT_SECONDS) { callback ->
        runtime.executeCommand(
            authority,
            requestId = id("$suffix-request"),
            sessionId = session.sessionId,
            expectedSessionRevision = session.sessionRevision,
            commandId = id("$suffix-command"),
            intent = intent,
            dispatchGrant = id("$suffix-grant"),
            callback = callback,
        )
    }

    private fun awaitWitness(
        runtime: MoonlightEmbeddedRuntime,
        authority: MoonlightAuthority,
        session: MoonlightBoundSession,
    ): MoonlightOutputWitnessSnapshot {
        val deadline = SystemClock.elapsedRealtime() + OUTPUT_TIMEOUT_SECONDS * 1_000
        var last: MoonlightOutputWitnessSnapshot? = null
        while (SystemClock.elapsedRealtime() < deadline) {
            last = runtime.outputWitness(authority, session.sessionId, session.sessionRevision)
            if (last.renderedFrameCount == 1 && last.acceptedAudioWriteCount == 1) return last
            SystemClock.sleep(POLL_MILLIS)
        }
        throw AssertionError(
            "exact session did not produce rendered-frame and accepted-PCM witnesses: " +
                "frame=${last?.renderedFrameCount ?: 0},audio=${last?.acceptedAudioWriteCount ?: 0}",
        )
    }

    private fun dispatchOwnedKeyA() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = AtomicReference<LarenorMoonlightGame?>()
        val deadline = SystemClock.elapsedRealtime() + ACTIVITY_TIMEOUT_SECONDS * 1_000
        while (activity.get() == null && SystemClock.elapsedRealtime() < deadline) {
            instrumentation.runOnMainSync {
                activity.set(
                    ActivityLifecycleMonitorRegistry.getInstance()
                        .getActivitiesInStage(Stage.RESUMED)
                        .filterIsInstance<LarenorMoonlightGame>()
                        .singleOrNull(),
                )
            }
            if (activity.get() == null) SystemClock.sleep(POLL_MILLIS)
        }
        val game = requireNotNull(activity.get())
        instrumentation.runOnMainSync {
            val now = SystemClock.uptimeMillis()
            game.dispatchKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, 0))
            game.dispatchKeyEvent(KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, KeyEvent.KEYCODE_A, 0))
        }
    }

    private fun registration(
        raw: String,
        pairingRevision: Long,
        registrationRevision: Long,
        previousApps: Map<String, String>,
    ): RegistrationFacts {
        require(raw.toByteArray().size <= MAX_OBSERVATION_BYTES)
        val value = JSONObject(raw)
        require(value.getInt("schemaVersion") == 1)
        val receiptId = value.getString("receiptId").also(::requireIdentityValue)
        val catalogRevision = value.getLong("catalogRevision").also(::requireRevisionValue)
        val array = value.getJSONArray("apps")
        require(array.length() in 1..MAX_APPS)
        val seen = linkedSetOf<String>()
        val apps = (0 until array.length()).map { index ->
            val app = array.getJSONObject(index)
            val observationId = app.getString("observationId").also(::requireIdentityValue)
            require(seen.add(observationId))
            val name = app.getString("name").also { require(it.isNotBlank() && it.length <= 160) }
            val revision = app.getLong("revision").also(::requireRevisionValue)
            RegisteredApp(
                observationId = observationId,
                appId = previousApps[observationId] ?: id("core-app-$observationId"),
                appRevision = revision,
                name = name,
            )
        }
        val registration = MoonlightCoreRegistration(
            nativeReceiptId = receiptId,
            registrationRevision = registrationRevision,
            hostId = id("core-host"),
            hostRevision = 1,
            pairingRevision = pairingRevision,
            catalogRevision = catalogRevision,
            apps = apps.mapIndexed { index, app -> index to (app.appId to app.appRevision) }.toMap(),
        )
        return RegistrationFacts(registration, apps, apps.associate { it.observationId to it.appId })
    }

    private fun MoonlightQualityOption.selected() = MoonlightSelectedQuality(
        codec = codec,
        codecId = codecId,
        codecRevision = codecRevision,
        displayId = displayId,
        displayRevision = displayRevision,
        networkId = networkId,
        networkRevision = networkRevision,
        policyId = policyId,
        policyRevision = policyRevision,
        widthPixels = widthPixels,
        heightPixels = heightPixels,
        framesPerSecond = framesPerSecond,
        bitrateKbps = bitrateKbps,
        frameQueueDepth = frameQueueDepth,
        inputQueueDepth = inputQueueDepth,
        secureSurface = secureSurface,
    )

    private fun authority(): MoonlightAuthority {
        val scope = MoonlightScope(id("core"), id("home"), id("account"), id("family"))
        val clientInstanceId = id("client-instance")
        return MoonlightAuthority(
            authorityId = sha256(
                "authority\u0000${scope.storageKey}\u0000$clientInstanceId".toByteArray(),
            ).hex().take(32),
            epoch = publicRevision("1", "1", "1", "1", "1", "1", "true", "true", clientInstanceId),
            scope = scope,
            clientInstanceId = clientInstanceId,
            accountRevision = 1,
            pinRevision = 1,
            pinConfigured = true,
            pinUnlocked = true,
            routeRevision = 1,
            lifecycleRevision = 1,
            idleRevision = 1,
            interactionRevision = 1,
        )
    }

    private fun id(label: String): String = sha256("$idSeed\u0000$label".toByteArray()).hex().take(32)

    private fun expiresAt(seconds: Long = AUTHORIZATION_SECONDS): Double =
        System.currentTimeMillis() / 1_000.0 + seconds

    private fun requireIdentityValue(value: String) = require(IDENTITY.matches(value))

    private fun requireRevisionValue(value: Long) = require(value in 1..MAX_JS_REVISION)

    private fun <T> awaitResult(
        timeoutSeconds: Long,
        begin: ((Result<T>) -> Unit) -> Unit,
    ): T {
        val delivered = CountDownLatch(1)
        val results = mutableListOf<Result<T>>()
        begin { value ->
            val first = synchronized(results) {
                if (results.isNotEmpty()) false else {
                    results += value
                    true
                }
            }
            if (first) delivered.countDown()
        }
        if (!delivered.await(timeoutSeconds, TimeUnit.SECONDS)) {
            throw AssertionError("owned Sunshine operation did not complete within its bound")
        }
        return synchronized(results) { results.single() }.getOrThrow()
    }

    private class LoopbackPinPresenter(
        private val nonce: String,
        private val port: Int,
    ) : MoonlightPinPresenter {
        private val used = AtomicBoolean(false)

        override fun show(pin: String, cancel: () -> Unit): AutoCloseable {
            require(used.compareAndSet(false, true))
            require(PIN.matches(pin))
            val payload =
                "{\"schemaVersion\":1,\"nonce\":\"$nonce\",\"pin\":\"$pin\"}\n"
                    .toByteArray(Charsets.US_ASCII)
            require(payload.size <= MAX_PIN_PAYLOAD_BYTES)
            val closed = AtomicBoolean(false)
            val activeSocket = AtomicReference<Socket?>()
            val sender = Thread({
                try {
                    Socket().use { socket ->
                        if (closed.get() || !activeSocket.compareAndSet(null, socket)) return@use
                        if (closed.get()) return@use
                        socket.tcpNoDelay = true
                        socket.connect(
                            InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), port),
                            PIN_CONNECT_TIMEOUT_MILLIS,
                        )
                        socket.getOutputStream().apply {
                            write(payload)
                            flush()
                        }
                    }
                } catch (_: Exception) {
                    // The real pairing operation remains bounded and fails if
                    // the private one-use PIN cannot reach the owned host.
                } finally {
                    activeSocket.set(null)
                    payload.fill(0)
                }
            }, "f60-owned-pin-sender").apply {
                isDaemon = true
                start()
            }
            return AutoCloseable {
                closed.set(true)
                runCatching { activeSocket.getAndSet(null)?.close() }
                sender.interrupt()
                payload.fill(0)
            }
        }
    }

    private data class RegisteredApp(
        val observationId: String,
        val appId: String,
        val appRevision: Long,
        val name: String,
    )

    private data class RegistrationFacts(
        val registration: MoonlightCoreRegistration,
        val apps: List<RegisteredApp>,
        val appsByObservation: Map<String, String>,
    )

    companion object {
        private const val REQUIRED_ARGUMENT = "larenorF60OwnedStream"
        private const val MDNS_INSTANCE_ARGUMENT = "larenorF60OwnedMdnsInstance"
        private const val PIN_NONCE_ARGUMENT = "larenorF60PinNonce"
        private const val PIN_PORT_ARGUMENT = "larenorF60PinPort"
        private const val PIN_PORT = 49_361
        private const val SUNSHINE_PORT = 47_989
        private const val OWNED_DISPLAY_NAME = "Larenor-F60-Owned"
        private const val OWNED_APP_NAME = "Desktop"
        private const val OWNED_BITRATE_KBPS = 2_000
        private const val MAXIMUM_IDLE_SECONDS = 300
        private const val MAXIMUM_SESSION_SECONDS = 600
        private const val AUTHORIZATION_SECONDS = 300L
        private const val DISCOVERY_TIMEOUT_MILLIS = 20_000L
        private const val DISCOVERY_DELIVERY_SECONDS = 25L
        private const val PAIR_TIMEOUT_SECONDS = 90L
        private const val CATALOG_TIMEOUT_SECONDS = 60L
        private const val COMMAND_TIMEOUT_SECONDS = 90L
        private const val OUTPUT_TIMEOUT_SECONDS = 120L
        private const val ACTIVITY_TIMEOUT_SECONDS = 30L
        private const val REVOKE_TIMEOUT_SECONDS = 60L
        private const val POLL_MILLIS = 100L
        private const val PIN_CONNECT_TIMEOUT_MILLIS = 5_000
        private const val MAX_PIN_PAYLOAD_BYTES = 256
        private const val MAX_OBSERVATION_BYTES = 64 * 1024
        private const val MAX_APPS = 256
        private const val MAX_JS_REVISION = 9_007_199_254_740_991L
        private val NONCE = Regex("^[0-9a-f]{64}$")
        private val MDNS_INSTANCE = Regex("^[A-Za-z0-9-]{1,63}$")
        private val PIN = Regex("^[0-9]{4}$")
        private val IDENTITY = Regex("^[0-9a-f]{32}$")
        private lateinit var idSeed: String
    }
}
