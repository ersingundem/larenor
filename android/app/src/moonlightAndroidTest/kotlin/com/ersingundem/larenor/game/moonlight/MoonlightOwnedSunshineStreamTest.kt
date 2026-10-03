package com.ersingundem.larenor.game.moonlight

import android.content.SharedPreferences
import android.os.SystemClock
import android.preference.PreferenceManager
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.ersingundem.larenor.MainActivity
import com.limelight.binding.input.virtual_controller.DigitalButton
import com.limelight.binding.input.virtual_controller.DigitalPad
import com.limelight.binding.input.virtual_controller.LeftAnalogStick
import com.limelight.binding.input.virtual_controller.LeftTrigger
import com.limelight.binding.input.virtual_controller.RightAnalogStick
import com.limelight.binding.input.virtual_controller.RightTrigger
import com.limelight.binding.input.virtual_controller.VirtualControllerElement
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
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
    fun productionNsdPairCatalogTwoStreamLifetimesTouchStopDisconnectAndLocalRetirement() {
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
        assertPinAcknowledgementParserRejectsInvalidFrames()

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
            val oscFixture = ScopedOscPreferenceFixture(
                @Suppress("DEPRECATION")
                PreferenceManager.getDefaultSharedPreferences(
                    MoonlightScopedContext.create(currentActivity.applicationContext, authority.scope),
                ),
            )
            try {
                oscFixture.enable()
                val nativeBinding = value.bindAuthority(authority)
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
                assertStreamCommandObserved(value, authority, nativeBinding, session, streaming)
                OwnedControlClient(nonce, CONTROL_PORT).use { control ->
                    val baseline = value.outputWitness(
                        authority, session.sessionId, session.sessionRevision,
                    )
                    assertEquals(
                        "owned audio must begin only after the exact post-connection arm",
                        0,
                        baseline.acceptedAudioWriteCount,
                    )
                    control.exchange("audio_ready", "audio_armed")
                    val witness = awaitWitness(value, authority, session)
                    assertEquals(1, witness.renderedFrameCount)
                    assertEquals(1, witness.acceptedAudioWriteCount)
                    val firstGame = currentOwnedGame()
                    dispatchOwnedKeyA(firstGame)
                    control.exchange("touch_ready", "touch_armed")
                    dispatchOwnedTouchAndMouse(firstGame)
                    control.exchange("touch_sent", "touch_observed")
                    control.exchange("gamepad_ready", "gamepad_armed")
                    dispatchOwnedOscA(firstGame)
                    control.exchange("gamepad_sent", "gamepad_observed")

                    val stopped = command(value, authority, session, "stop", "stop")
                    assertEquals("native_observed", stopped.state)
                    assertEquals("stopped", stopped.result)
                    assertEquals("connectionStopped", stopped.observationKind)
                    value.retireExactSession(session.sessionId, session.sessionRevision)
                    value.bindAuthority(authority)

                    val disconnectedSession = session.copy(
                        sessionId = id("disconnect-session"),
                        sessionRevision = 2,
                        expiresAtEpochSeconds = expiresAt(MAXIMUM_SESSION_SECONDS.toLong()),
                    )
                    value.bindSession(authority, disconnectedSession)
                    val relaunched = command(
                        value, authority, disconnectedSession, "launch", "disconnect-launch",
                    )
                    assertEquals("native_observed", relaunched.state)
                    assertEquals("appRunning", relaunched.result)
                    assertEquals("currentGameMatched", relaunched.observationKind)
                    val reconnected = command(
                        value, authority, disconnectedSession, "stream", "disconnect-stream",
                    )
                    assertEquals("native_observed", reconnected.state)
                    assertEquals("streaming", reconnected.result)
                    assertEquals("connectionStarted", reconnected.observationKind)
                    val secondBaseline = value.outputWitness(
                        authority,
                        disconnectedSession.sessionId,
                        disconnectedSession.sessionRevision,
                    )
                    assertEquals(
                        "successor audio must begin only after its exact post-connection arm",
                        0,
                        secondBaseline.acceptedAudioWriteCount,
                    )
                    control.exchange("audio_ready", "audio_armed")
                    val secondWitness = awaitWitness(value, authority, disconnectedSession)
                    assertEquals(1, secondWitness.renderedFrameCount)
                    assertEquals(1, secondWitness.acceptedAudioWriteCount)

                    control.exchange("disconnect_ready", "owned_sunshine_stopped")
                    val terminated = awaitRemoteTermination(
                        value, authority, disconnectedSession,
                    )
                    assertEquals(MoonlightLeaseState.RETIRED, terminated.state)
                    assertEquals("connectionTerminated", terminated.observationKind)
                    val reconciled = requireNotNull(value.reconcile(
                        authority,
                        id("disconnect-stream-reconcile"),
                        "command",
                        id("disconnect-stream-command"),
                    ) as? MoonlightCommandReceipt)
                    assertEquals("native_observed", reconciled.state)
                    assertEquals("streaming", reconciled.result)
                    assertEquals("connectionStarted", reconciled.observationKind)
                    assertEquals(reconnected.readbackRevision, reconciled.readbackRevision)
                    assertEquals(reconnected.nativeReceiptDigest, reconciled.nativeReceiptDigest)
                    value.retireExactSession(
                        disconnectedSession.sessionId, disconnectedSession.sessionRevision,
                    )
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
                }
            } finally {
                try {
                    value.close()
                } finally {
                    try {
                        oscFixture.restore()
                    } finally {
                        MoonlightForegroundLeaseRegistry.clearForTest()
                    }
                }
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

    /**
     * Preserve the strict stream result while exposing only process-private,
     * fixed-enum state if the provider callback was collapsed to unknown.
     * No launch token, provider identity, endpoint, or native payload enters
     * the assertion consumed by the owned-host diagnostic parser.
     */
    private fun assertStreamCommandObserved(
        runtime: MoonlightEmbeddedRuntime,
        authority: MoonlightAuthority,
        nativeBinding: Pair<String, Long>,
        session: MoonlightBoundSession,
        receipt: MoonlightCommandReceipt,
    ) {
        if (receipt.state == "native_observed" && receipt.result == "streaming" &&
            receipt.observationKind == "connectionStarted"
        ) return
        val active = runCatching {
            runtime.foregroundLease(
                authority,
                nativeBinding.first,
                nativeBinding.second,
                session.sessionId,
                session.sessionRevision,
            ).second
        }.getOrNull()
        val terminal = if (active == null) runCatching {
            runtime.terminalWitness(authority, session.sessionId, session.sessionRevision)
        }.getOrNull() else null
        val leaseClaim = when (active?.state ?: terminal?.state) {
            MoonlightLeaseState.TRANSFER_PENDING -> "transferPending"
            MoonlightLeaseState.GAME_VISIBLE -> "gameVisible"
            MoonlightLeaseState.UNCERTAIN -> "uncertain"
            MoonlightLeaseState.RETIRED -> "retired"
            else -> "absentOrUnreadable"
        }
        val classification = when (leaseClaim) {
            "transferPending" -> "leaseTransferPending"
            "gameVisible" -> "leaseGameVisible"
            "uncertain" -> "leaseUncertain"
            "retired" -> "leaseRetired"
            else -> "leaseAbsentOrUnreadable"
        }
        val state = receipt.state.takeIf { it in setOf("native_observed", "unknown") } ?: "invalid"
        val result = receipt.result.takeIf { it in setOf("streaming", "unknown") } ?: "invalid"
        val kind = receipt.observationKind.takeIf {
            it in setOf("connectionStarted", "unknown")
        } ?: "invalid"
        val dispatch = runCatching {
            runtime.streamDispatchTrace(
                authority,
                id("stream-request"),
                session.sessionId,
                session.sessionRevision,
                id("stream-command"),
            )
        }.getOrNull()
        val dispatchMarker = dispatch?.let {
            "\nF60_STREAM_DISPATCH_V1|stage=${it.stage}|failureClass=${it.failureClass}|" +
                "runtimeFailure=${it.runtimeFailure}"
        }.orEmpty()
        val boundaries = runCatching {
            runtime.connectionBoundaryDiagnostic(authority, session.sessionId, session.sessionRevision)
        }.getOrNull()
        val boundaryMarker = boundaries?.let {
            "\nF60_CONNECTION_BOUNDARIES_V2|surfaceCreated=${it.surfaceCreated}|" +
                "positiveSurfaceChanged=${it.positiveSurfaceChanged}|stageStarted=${it.stageStarted}|" +
                "stageCompleted=${it.stageCompleted}|stageFailed=${it.stageFailed}|" +
                "connectionStarted=${it.connectionStarted}|" +
                "failureStage=${it.failureStage.wireName}|failureSignal=${it.failureSignal.wireName}"
        }.orEmpty()
        throw AssertionError(
            "F60_STREAM_COMMAND_V1|state=$state|result=$result|kind=$kind|" +
                "leaseClaim=$leaseClaim|outcome=strictFailure|classification=$classification" +
                dispatchMarker + boundaryMarker,
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
            "F60_OUTPUT_WITNESS_V1|" +
                "renderedFrameObserved=${last?.renderedFrameCount == 1}|" +
                "acceptedAudioObserved=${last?.acceptedAudioWriteCount == 1}",
        )
    }

    private fun awaitRemoteTermination(
        runtime: MoonlightEmbeddedRuntime,
        authority: MoonlightAuthority,
        session: MoonlightBoundSession,
    ): MoonlightTerminalWitnessSnapshot {
        val deadline = SystemClock.elapsedRealtime() + REMOTE_TERMINATION_TIMEOUT_SECONDS * 1_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val witness = runtime.terminalWitness(
                authority, session.sessionId, session.sessionRevision,
            )
            if (witness != null) return witness
            SystemClock.sleep(POLL_MILLIS)
        }
        throw AssertionError("exact second session did not receive a terminal Game callback")
    }

    private fun currentOwnedGame(): LarenorMoonlightGame {
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
        return requireNotNull(activity.get())
    }

    private fun dispatchOwnedKeyA(game: LarenorMoonlightGame) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val now = SystemClock.uptimeMillis()
            game.dispatchKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, 0))
            game.dispatchKeyEvent(KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, KeyEvent.KEYCODE_A, 0))
        }
    }

    private fun dispatchOwnedTouchAndMouse(game: LarenorMoonlightGame) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val downTime = SystemClock.uptimeMillis()
            val touchActions = listOf(
                Triple(MotionEvent.ACTION_DOWN, 96f, 96f),
                Triple(MotionEvent.ACTION_MOVE, 132f, 118f),
                Triple(MotionEvent.ACTION_UP, 132f, 118f),
            )
            touchActions.forEachIndexed { index, (action, x, y) ->
                pointerEvent(
                    downTime = downTime,
                    eventTime = downTime + index + 1L,
                    action = action,
                    source = InputDevice.SOURCE_TOUCHSCREEN,
                    toolType = MotionEvent.TOOL_TYPE_FINGER,
                    x = x,
                    y = y,
                ).use(game::dispatchTouchEvent)
            }
            pointerEvent(
                downTime = downTime,
                eventTime = downTime + 4,
                action = MotionEvent.ACTION_MOVE,
                source = InputDevice.SOURCE_MOUSE_RELATIVE,
                toolType = MotionEvent.TOOL_TYPE_MOUSE,
                relativeX = 18f,
                relativeY = 12f,
            ).use(game::dispatchGenericMotionEvent)
            pointerEvent(
                downTime = downTime,
                eventTime = downTime + 5,
                action = MotionEvent.ACTION_BUTTON_PRESS,
                source = InputDevice.SOURCE_MOUSE_RELATIVE,
                toolType = MotionEvent.TOOL_TYPE_MOUSE,
                buttonState = MotionEvent.BUTTON_PRIMARY,
            ).use(game::dispatchGenericMotionEvent)
            pointerEvent(
                downTime = downTime,
                eventTime = downTime + 6,
                action = MotionEvent.ACTION_BUTTON_RELEASE,
                source = InputDevice.SOURCE_MOUSE_RELATIVE,
                toolType = MotionEvent.TOOL_TYPE_MOUSE,
            ).use(game::dispatchGenericMotionEvent)
        }
    }

    private fun dispatchOwnedOscA(game: LarenorMoonlightGame) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val elements = mutableListOf<VirtualControllerElement>()
            collectVisibleControllerElements(game.window.decorView, elements)
            assertEquals(
                "source-locked default Moonlight OSC hierarchy changed",
                listOf(
                    DigitalPad::class.java,
                    DigitalButton::class.java,
                    DigitalButton::class.java,
                    DigitalButton::class.java,
                    DigitalButton::class.java,
                    LeftTrigger::class.java,
                    RightTrigger::class.java,
                    DigitalButton::class.java,
                    DigitalButton::class.java,
                    LeftAnalogStick::class.java,
                    RightAnalogStick::class.java,
                    DigitalButton::class.java,
                    DigitalButton::class.java,
                    DigitalButton::class.java,
                ),
                elements.map { it.javaClass },
            )
            val aButton = elements[1] as DigitalButton
            assertTrue("Moonlight OSC A button is not attached", aButton.isAttachedToWindow)
            assertTrue("Moonlight OSC A button has no touch target", aButton.width > 0 && aButton.height > 0)
            val downTime = SystemClock.uptimeMillis()
            pointerEvent(
                downTime = downTime,
                eventTime = downTime,
                action = MotionEvent.ACTION_DOWN,
                source = InputDevice.SOURCE_TOUCHSCREEN,
                toolType = MotionEvent.TOOL_TYPE_FINGER,
                x = aButton.width / 2f,
                y = aButton.height / 2f,
            ).use(aButton::dispatchTouchEvent)
            pointerEvent(
                downTime = downTime,
                eventTime = downTime + 1,
                action = MotionEvent.ACTION_UP,
                source = InputDevice.SOURCE_TOUCHSCREEN,
                toolType = MotionEvent.TOOL_TYPE_FINGER,
                x = aButton.width / 2f,
                y = aButton.height / 2f,
            ).use(aButton::dispatchTouchEvent)
        }
    }

    private fun collectVisibleControllerElements(
        view: View,
        destination: MutableList<VirtualControllerElement>,
    ) {
        if (view is VirtualControllerElement && view.visibility == View.VISIBLE && view.isShown) {
            destination += view
        }
        if (view is ViewGroup) {
            repeat(view.childCount) { index ->
                collectVisibleControllerElements(view.getChildAt(index), destination)
            }
        }
    }

    private fun pointerEvent(
        downTime: Long,
        eventTime: Long,
        action: Int,
        source: Int,
        toolType: Int,
        x: Float = 0f,
        y: Float = 0f,
        relativeX: Float = 0f,
        relativeY: Float = 0f,
        buttonState: Int = 0,
    ): MotionEvent {
        val properties = MotionEvent.PointerProperties().apply {
            id = 0
            this.toolType = toolType
        }
        val coordinates = MotionEvent.PointerCoords().apply {
            this.x = x
            this.y = y
            pressure = 1f
            size = 1f
            setAxisValue(MotionEvent.AXIS_RELATIVE_X, relativeX)
            setAxisValue(MotionEvent.AXIS_RELATIVE_Y, relativeY)
        }
        return MotionEvent.obtain(
            downTime,
            eventTime,
            action,
            1,
            arrayOf(properties),
            arrayOf(coordinates),
            0,
            buttonState,
            1f,
            1f,
            0,
            0,
            source,
            0,
        )
    }

    private inline fun MotionEvent.use(block: (MotionEvent) -> Boolean) {
        try {
            assertTrue("owned Game did not accept a production input event", block(this))
        } finally {
            recycle()
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
            val delivered = CountDownLatch(1)
            val deliveryFailure = AtomicReference<Throwable?>()
            val deadline = System.nanoTime() +
                TimeUnit.SECONDS.toNanos(PIN_DELIVERY_TIMEOUT_SECONDS)
            val sender = Thread({
                try {
                    Socket().use { socket ->
                        if (closed.get() || !activeSocket.compareAndSet(null, socket)) return@use
                        if (closed.get()) return@use
                        socket.tcpNoDelay = true
                        socket.connect(
                            InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), port),
                            minOf(PIN_CONNECT_TIMEOUT_MILLIS, remainingPinDeliveryMillis(deadline)),
                        )
                        socket.getOutputStream().apply {
                            write(payload)
                            flush()
                        }
                        socket.soTimeout = remainingPinDeliveryMillis(deadline)
                        readPinAcknowledgement(socket.getInputStream())
                    }
                } catch (failure: Exception) {
                    deliveryFailure.compareAndSet(null, failure)
                } finally {
                    activeSocket.set(null)
                    payload.fill(0)
                    delivered.countDown()
                }
            }, "f60-owned-pin-sender").apply {
                isDaemon = true
                start()
            }
            if (!delivered.await(PIN_DELIVERY_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                closed.set(true)
                runCatching { activeSocket.getAndSet(null)?.close() }
                sender.interrupt()
                throw AssertionError("owned PIN delivery did not complete within its bound")
            }
            if (deliveryFailure.get() != null) {
                throw AssertionError("owned PIN delivery failed")
            }
            return AutoCloseable {
                closed.set(true)
                runCatching { activeSocket.getAndSet(null)?.close() }
                sender.interrupt()
                payload.fill(0)
            }
        }
    }

    private fun assertPinAcknowledgementParserRejectsInvalidFrames() {
        readPinAcknowledgement(ByteArrayInputStream(PIN_ACKNOWLEDGEMENT))
        for (invalid in listOf(
            byteArrayOf(),
            "LRNPIN2\n".toByteArray(Charsets.US_ASCII),
            PIN_ACKNOWLEDGEMENT + byteArrayOf('x'.code.toByte()),
        )) {
            require(runCatching {
                readPinAcknowledgement(ByteArrayInputStream(invalid))
            }.isFailure)
        }
    }

    private class OwnedControlClient(nonce: String, port: Int) : AutoCloseable {
        private val expectedNonce = nonce.also { require(NONCE.matches(it)) }
        private val socket = Socket().apply {
            tcpNoDelay = true
            soTimeout = CONTROL_READ_TIMEOUT_MILLIS
            connect(
                InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), port),
                CONTROL_CONNECT_TIMEOUT_MILLIS,
            )
        }

        fun exchange(sentPhase: String, expectedPhase: String) {
            require(CONTROL_PHASE.matches(sentPhase) && CONTROL_PHASE.matches(expectedPhase))
            val payload = JSONObject()
                .put("schemaVersion", 1)
                .put("nonce", expectedNonce)
                .put("phase", sentPhase)
                .toString()
                .plus("\n")
                .toByteArray(Charsets.US_ASCII)
            require(payload.size <= MAX_CONTROL_PAYLOAD_BYTES)
            socket.getOutputStream().apply {
                write(payload)
                flush()
            }
            val bytes = ArrayList<Byte>()
            val deadline = SystemClock.elapsedRealtime() + CONTROL_READ_TIMEOUT_MILLIS
            while (bytes.size <= MAX_CONTROL_PAYLOAD_BYTES) {
                val remaining = deadline - SystemClock.elapsedRealtime()
                if (remaining <= 0) throw AssertionError("owned control phase ACK timed out")
                socket.soTimeout = remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val next = socket.getInputStream().read()
                if (next < 0) throw AssertionError("owned control channel closed before its phase ACK")
                if (next == '\n'.code) break
                require(next in 0x20..0x7e)
                bytes += next.toByte()
            }
            require(bytes.size in 1 until MAX_CONTROL_PAYLOAD_BYTES)
            val value = JSONObject(bytes.toByteArray().toString(Charsets.US_ASCII))
            require(value.length() == 3)
            require(value.getInt("schemaVersion") == 1)
            require(value.getString("nonce") == expectedNonce)
            require(value.getString("phase") == expectedPhase)
            require(value.keys().asSequence().toSet() == setOf("schemaVersion", "nonce", "phase"))
        }

        override fun close() {
            runCatching { socket.close() }
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

    private class ScopedOscPreferenceFixture(
        private val preferences: SharedPreferences,
    ) {
        private val previous = OSC_KEYS.associateWith { key ->
            preferences.all[key].also { value -> require(value == null || value is Boolean) }
        }

        fun enable() {
            require(!preferences.getBoolean(OSC_ONLY_L3_R3, false))
            require(!preferences.getBoolean(OSC_FLIP_FACE_BUTTONS, false))
            check(preferences.edit().putBoolean(OSC_ENABLED, true).commit())
            check(preferences.getBoolean(OSC_ENABLED, false))
        }

        fun restore() {
            val editor = preferences.edit()
            previous.forEach { (key, value) ->
                if (value == null) editor.remove(key) else editor.putBoolean(key, value as Boolean)
            }
            check(editor.commit())
        }
    }

    companion object {
        private const val REQUIRED_ARGUMENT = "larenorF60OwnedStream"
        private const val MDNS_INSTANCE_ARGUMENT = "larenorF60OwnedMdnsInstance"
        private const val PIN_NONCE_ARGUMENT = "larenorF60PinNonce"
        private const val PIN_PORT_ARGUMENT = "larenorF60PinPort"
        private const val PIN_PORT = 49_361
        private const val CONTROL_PORT = 49_362
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
        private const val REMOTE_TERMINATION_TIMEOUT_SECONDS = 60L
        private const val ACTIVITY_TIMEOUT_SECONDS = 30L
        private const val REVOKE_TIMEOUT_SECONDS = 60L
        private const val POLL_MILLIS = 100L
        private const val PIN_CONNECT_TIMEOUT_MILLIS = 5_000
        private const val PIN_DELIVERY_TIMEOUT_SECONDS = 10L
        private const val CONTROL_CONNECT_TIMEOUT_MILLIS = 5_000
        private const val CONTROL_READ_TIMEOUT_MILLIS = 90_000
        private const val MAX_PIN_PAYLOAD_BYTES = 256
        private val PIN_ACKNOWLEDGEMENT = "LRNPIN1\n".toByteArray(Charsets.US_ASCII)

        private fun readPinAcknowledgement(input: InputStream) {
            val observed = ByteArray(PIN_ACKNOWLEDGEMENT.size)
            try {
                var offset = 0
                while (offset < observed.size) {
                    val read = input.read(observed, offset, observed.size - offset)
                    if (read < 0) throw IOException("owned PIN acknowledgement was unavailable")
                    offset += read
                }
                if (!observed.contentEquals(PIN_ACKNOWLEDGEMENT) || input.read() != -1) {
                    throw IOException("owned PIN acknowledgement was invalid")
                }
            } finally {
                observed.fill(0)
            }
        }

        private fun remainingPinDeliveryMillis(deadlineNanos: Long): Int {
            val remaining = deadlineNanos - System.nanoTime()
            if (remaining <= 0) {
                throw SocketTimeoutException("owned PIN delivery exceeded its bound")
            }
            return TimeUnit.NANOSECONDS.toMillis(remaining)
                .coerceAtLeast(1)
                .coerceAtMost(Int.MAX_VALUE.toLong())
                .toInt()
        }

        private const val MAX_CONTROL_PAYLOAD_BYTES = 512
        private const val OSC_ENABLED = "checkbox_show_onscreen_controls"
        private const val OSC_ONLY_L3_R3 = "checkbox_only_show_L3R3"
        private const val OSC_FLIP_FACE_BUTTONS = "checkbox_flip_face_buttons"
        private val OSC_KEYS = setOf(OSC_ENABLED, OSC_ONLY_L3_R3, OSC_FLIP_FACE_BUTTONS)
        private const val MAX_OBSERVATION_BYTES = 64 * 1024
        private const val MAX_APPS = 256
        private const val MAX_JS_REVISION = 9_007_199_254_740_991L
        private val NONCE = Regex("^[0-9a-f]{64}$")
        private val MDNS_INSTANCE = Regex("^[A-Za-z0-9-]{1,63}$")
        private val PIN = Regex("^[0-9]{4}$")
        private val CONTROL_PHASE = Regex("^[a-z_]{1,48}$")
        private val IDENTITY = Regex("^[0-9a-f]{32}$")
        private lateinit var idSeed: String
    }
}
