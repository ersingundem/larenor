package com.ersingundem.larenor.rdp

import android.content.Context
import android.util.AtomicFile
import android.Manifest
import androidx.test.core.app.ActivityScenario
import androidx.lifecycle.Lifecycle
import com.ersingundem.larenor.MainActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime
import com.ersingundem.larenor.rdp.packaged.RdpPackagedOpenDiagnosticSnapshot
import com.ersingundem.larenor.rdp.packaged.packagedConnectionUri
import com.freerdp.freerdpcore.application.GlobalApp
import com.freerdp.freerdpcore.services.LibFreeRDP
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * F62 acceptance against an owned FreeRDP shadow host started by CI.
 *
 * The fixture is outside the app process and enforces NLA with an ephemeral
 * SAM credential. This exercises the receipted native AAR rather than a JVM
 * backend double. Physical Windows, Huawei and DeX acceptance remains manual.
 */
@RunWith(AndroidJUnit4::class)
class RdpPackagedHostAcceptanceTest {
    @Test
    fun nlaShadowBaselineProvesPinnedFramesKeyEffectResizeAndCleanClose() =
        diagnoseOwnedTestBody { entered, registerFailureMarker ->
            val arguments = InstrumentationRegistry.getArguments()
            val diagnosticNonce = arguments.required("rdpDiagnosticNonce")
            val controlSourceSha256 = arguments.required("rdpControlSourceSha256")
            val context = ApplicationProvider.getApplicationContext<Context>()
            val diagnostic = OwnedLifecycleDiagnostic(
                AtomicLifecycleStorage(context, diagnosticNonce),
                entered,
            )
            val effectControl = OwnedEffectControl(
                AtomicEffectControlStorage(context, diagnosticNonce),
                diagnosticNonce,
                controlSourceSha256,
            )
            registerFailureMarker(diagnostic::bodyFailure)
            diagnostic.enter("testInitialization")

            val host = arguments.required("rdpHost")
            val port = arguments.required("rdpPort").toInt()
            val username = arguments.required("rdpUsername")
            val domain = arguments.required("rdpDomain")
            val passwordValue = arguments.required("rdpPassword")
            assertDiagnosticFailuresAreSecondary()
            InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(
                context.packageName, Manifest.permission.RECORD_AUDIO,
            )
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.moveToState(Lifecycle.State.RESUMED)
            val runtime = focusedRuntimeWithMicrophoneGrant(scenario)

            diagnostic.enter("connectionValidation")
            assertConnectionInfoParses(
                context,
                packagedConnectionUri(host, port, username, 1280, 800, true),
            )
            assertConnectionInfoParses(
                context,
                packagedConnectionUri(host, port, username, 1280, 800, false),
            )

            diagnostic.enter("runtimeValidation")
            assertTrue(RdpFreeRdpPackage.verify(runtime.identity()))
            val capabilities = RdpNativeCapabilities.parse(runtime.capabilities())
            assertTrue(capabilities.canConnect)
            assertTrue(capabilities.nla)
            assertTrue(capabilities.ime)
            assertTrue(capabilities.absolutePointer)
            assertTrue(capabilities.relativePointerNegotiation)
            assertTrue(capabilities.verticalWheel)
            assertEquals(setOf(100, 140, 180), capabilities.deviceScaleFactors)
            assertTrue(RdpClipboardMode.CLIENT_TO_REMOTE in capabilities.clipboardModes)
            assertTrue(capabilities.audio && capabilities.microphone && capabilities.files)
            assertTrue(capabilities.rdGateway)

            diagnostic.enter("providerInspection")
            val inspected = runtime.inspect(host, port, username)
            assertTrue(inspected.clientRequiresNla)
            assertEquals("TLSv1.2", inspected.minimumTlsPolicy)
            assertEquals(50, inspected.certificateFingerprint.length)
            assertTrue(Regex("SHA256:[A-Za-z0-9+/]{43}").matches(inspected.certificateFingerprint))

            val request = request(
                requestId = "62726270-0000-4000-8000-000000000001",
                host = host,
                port = port,
                username = username,
                domain = domain,
                fingerprint = inspected.certificateFingerprint,
                width = 1280,
                height = 800,
                clipboardMode = "clientToRemote",
                audio = true,
                microphone = true,
            )
            val security = CountDownLatch(1)
            val frameReady = ArrayBlockingQueue<Unit>(8)
            val frameCallbacks = BoundedFrameCallbacks()
            val closed = CountDownLatch(1)
            val observer = object : RdpNativeSessionObserver {
                override fun onSecurity() = security.countDown()
                override fun onFrame() {
                    frameCallbacks.observed()
                    frameReady.offer(Unit)
                }
                override fun onClosed(code: String?) = closed.countDown()
            }
            val password = passwordValue.toCharArray()
            diagnostic.enter("firstSessionOpen")
            val session = diagnoseOpen(runtime, request, diagnostic, "firstSessionOpen") {
                RdpNativeAdapter(RdpFreeRdpBackend(runtime)).open(
                    request,
                    RdpNativeSecrets.take(password, null),
                    observer,
                ) as RdpFreeRdpSession
            }

            var firstBodyCompleted = false
            try {
                diagnostic.enter("firstSecurityWait")
                assertTrue("native security callback", security.await(10, TimeUnit.SECONDS))
                assertTrue(
                    "first lifetime negotiated Unicode text input",
                    session.unicodeInputSupported,
                )
                assertTrue(
                    "session entered the active frame lifecycle",
                    session.phase == RdpJniPhase.ACTIVE ||
                        session.phase == RdpJniPhase.AWAITING_FRAME_ACK,
                )
                diagnostic.enter("initialFrameWait")
                val initial = awaitInitialFrame(
                    session, frameReady, frameCallbacks, diagnostic, 1280, 800, 30,
                )
                assertRenderedPixels(initial, 1280, 800)
                assertEquals(1L, initial.displayLayoutRevision)
                assertTrue(session.acknowledgeFrame(initial.sequence))

                val audioBaseline = session.audioObservation()
                assertEquals(RdpRemoteAudioState.PENDING, audioBaseline.state)
                assertFalse(audioBaseline.deviceOpen)
                assertEquals(0L, audioBaseline.acceptedCount)
                assertEquals(0L, audioBaseline.completedCount)
                diagnostic.enter("audioEffectWait")
                effectControl.armAudio()
                val audio = awaitRemoteAudio(session, audioBaseline, 30)
                assertEquals(RdpRemoteAudioState.PLAYING, audio.state)
                assertTrue(audio.deviceOpen)
                assertTrue(audio.acceptedCount >= audio.completedCount)
                assertTrue(audio.completedCount >= audioBaseline.completedCount + 1L)

                diagnostic.enter("microphoneOpenWait")
                val microphoneBaseline = awaitMicrophoneOpen(session, 30)
                diagnostic.enter("microphoneEffectWait")
                effectControl.armMicrophone()
                awaitMicrophoneHostEffect(context, diagnosticNonce, session, microphoneBaseline, 30)

                // The host runner observes this exact software HID key pair through XI2.
                // It changes the owned Xorg output only after the patched server observes
                // this session's exact DISP monitor layout.
                diagnostic.enter("keySubmission")
                assertTrue(session.key(1, 0x70004, true))
                assertTrue(session.key(2, 0x70004, false))

                diagnostic.enter("resizeSubmission")
                diagnoseStage(::RdpOwnedClientDispSubmissionFailure) {
                    assertTrue(
                        "client DISP monitor layout was submitted",
                        session.resize(3, RdpNativeDisplay(1024, 768, 100, 100, false, true)),
                    )
                }

                diagnostic.enter("resizedFrameWait")
                val resized = diagnoseStage(::RdpOwnedResizedFrameWaitFailure) {
                    awaitFrame(session, frameReady, 1024, 768, 30)
                }
                diagnoseStage(::RdpOwnedResizedFramePixelsFailure) {
                    assertRenderedPixels(resized, 1024, 768)
                    assertEquals(2L, resized.displayLayoutRevision)
                }
                val priorBackground = firstPixel(resized)
                diagnoseStage(::RdpOwnedResizedFrameAckFailure) {
                    assertTrue(session.acknowledgeFrame(resized.sequence))
                }

                diagnostic.enter("clipboardSubmission")
                val clipboard = "Larenor-F62-İş-😀\n\tv1".encodeToByteArray()
                diagnoseStage(::RdpOwnedClipboardSubmissionFailure) {
                    assertTrue(
                        "client-to-remote clipboard submission was accepted",
                        session.channel(4, RdpJniChannel.CLIPBOARD, clipboard),
                    )
                    assertTrue("clipboard caller bytes were wiped", clipboard.all { it == 0.toByte() })
                }
                diagnostic.enter("clipboardEffectWait")
                val clipboardFrame = diagnoseStage(::RdpOwnedClipboardEffectWaitFailure) {
                    awaitChangedPixelFrame(
                        session, frameReady, 1024, 768, priorBackground, 30,
                    )
                }
                assertRenderedPixels(clipboardFrame, 1024, 768)
                assertTrue(session.acknowledgeFrame(clipboardFrame.sequence))
                firstBodyCompleted = true
            } finally {
                if (firstBodyCompleted) diagnostic.enter("firstClose")
                diagnoseStage(::RdpOwnedCleanCloseFailure) {
                    session.close()
                }
            }
            diagnostic.enter("firstClosedValidation")
            diagnoseStage(::RdpOwnedCleanCloseFailure) {
                assertEquals(RdpJniPhase.CANCELLED, session.phase)
                assertTrue("session close callback", closed.await(5, TimeUnit.SECONDS))
            }
            diagnoseStage(::RdpOwnedCredentialClearFailure) {
                assertTrue(password.all { it == '\u0000' })
            }

            val disabledRequest = request(
                requestId = "62726270-0000-4000-8000-000000000002",
                host = host,
                port = port,
                username = username,
                domain = domain,
                fingerprint = inspected.certificateFingerprint,
                width = 1024,
                height = 768,
                clipboardMode = "disabled",
                audio = false,
                microphone = false,
            )
            val disabledSecurity = CountDownLatch(1)
            val disabledFrames = ArrayBlockingQueue<Unit>(8)
            val disabledClosed = CountDownLatch(1)
            val disabledObserver = object : RdpNativeSessionObserver {
                override fun onSecurity() = disabledSecurity.countDown()
                override fun onFrame() {
                    disabledFrames.offer(Unit)
                }
                override fun onClosed(code: String?) = disabledClosed.countDown()
            }
            val disabledPassword = passwordValue.toCharArray()
            diagnostic.enter("secondSessionOpen")
            val disabled = diagnoseOpen(runtime, disabledRequest, diagnostic, "secondSessionOpen") {
                RdpNativeAdapter(RdpFreeRdpBackend(runtime)).open(
                    disabledRequest,
                    RdpNativeSecrets.take(disabledPassword, null),
                    disabledObserver,
                ) as RdpFreeRdpSession
            }
            var secondBodyCompleted = false
            try {
                diagnostic.enter("secondSecurityWait")
                assertTrue(
                    "disabled lifetime native security callback",
                    disabledSecurity.await(10, TimeUnit.SECONDS),
                )
                assertTrue(
                    "disabled lifetime negotiated Unicode text input",
                    disabled.unicodeInputSupported,
                )
                diagnostic.enter("secondFrameWait")
                val frame = awaitFrame(disabled, disabledFrames, 1024, 768, 30)
                assertRenderedPixels(frame, 1024, 768)
                assertTrue(disabled.acknowledgeFrame(frame.sequence))
                val unavailable = assertThrows(RdpNativeFailure::class.java) {
                    disabled.audioObservation()
                }
                assertEquals("channelUnavailable", unavailable.code)
                val microphoneUnavailable = assertThrows(RdpNativeFailure::class.java) {
                    disabled.microphoneObservation()
                }
                assertEquals("channelUnavailable", microphoneUnavailable.code)
                diagnostic.enter("disabledClipboardCheck")
                val rejected = "must-not-cross-disabled-channel".encodeToByteArray()
                diagnoseStage(::RdpOwnedDisabledClipboardFailure) {
                    assertFalse(
                        "disabled clipboard is rejected before provider I/O",
                        disabled.channel(1, RdpJniChannel.CLIPBOARD, rejected),
                    )
                    assertTrue("disabled clipboard caller bytes were wiped", rejected.all { it == 0.toByte() })
                    assertTrue("disabled lifetime close callback", disabledClosed.await(5, TimeUnit.SECONDS))
                    assertEquals(RdpJniPhase.FAILED, disabled.phase)
                    assertEquals("channelUnavailable", disabled.failureCode)
                }
                secondBodyCompleted = true
            } finally {
                if (secondBodyCompleted) diagnostic.enter("secondClose")
                disabled.close()
            }
            diagnostic.enter("credentialValidation")
            diagnoseStage(::RdpOwnedCredentialClearFailure) {
                assertTrue(disabledPassword.all { it == '\u0000' })
            }
            diagnostic.enter("complete")
            effectControl.remove()
            diagnostic.remove()
            }
        }

    private fun focusedRuntimeWithMicrophoneGrant(
        scenario: ActivityScenario<MainActivity>,
    ): RdpPackagedRuntime {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        var runtime: RdpPackagedRuntime? = null
        val id = "62726270-0000-4000-8000-000000000001"
        while (System.nanoTime() < deadline && runtime == null) {
            scenario.onActivity { activity ->
                if (!activity.hasWindowFocus() || activity.isFinishing || activity.isDestroyed) {
                    return@onActivity
                }
                val field = MainActivity::class.java.getDeclaredField("rdpNative")
                field.isAccessible = true
                val bridge = field.get(activity) as? RdpNativeBridge ?: return@onActivity
                val result = object : MethodChannel.Result {
                    override fun success(value: Any?) {
                        assertEquals(mapOf("schemaVersion" to 4, "requestId" to id, "granted" to true), value)
                        runtime = RdpPackagedRuntime(activity)
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        throw AssertionError("owned microphone permission broker rejected: $code")
                    }
                    override fun notImplemented() = throw AssertionError("owned microphone permission unavailable")
                }
                bridge.onListen(id, object : EventChannel.EventSink {
                    override fun success(value: Any?) = Unit
                    override fun error(code: String, message: String?, details: Any?) = Unit
                    override fun endOfStream() = Unit
                })
                try {
                    bridge.onMethodCall(MethodCall("requestMicrophonePermission",
                        mapOf("schemaVersion" to 4, "requestId" to id)), result)
                } finally {
                    bridge.onCancel(id)
                }
            }
            if (runtime == null) Thread.sleep(25)
        }
        return runtime ?: throw AssertionError("owned resumed RDP activity was unavailable")
    }

    private inline fun <T> diagnoseOpen(
        runtime: RdpPackagedRuntime,
        request: RdpNativeRequest,
        diagnostic: OwnedLifecycleDiagnostic,
        stage: String,
        open: () -> T,
    ): T = try {
        open()
    } catch (failure: RdpNativeFailure) {
        // A diagnostic failure must never replace the original open failure.
        runCatching {
            runtime.consumeFailedOpenDiagnostic(request.requestId)?.let {
                diagnostic.openFailure(stage, failure.code, it)
            }
        }
        throw failure
    }

    private fun request(
        requestId: String,
        host: String,
        port: Int,
        username: String,
        domain: String,
        fingerprint: String,
        width: Int,
        height: Int,
        clipboardMode: String,
        audio: Boolean,
        microphone: Boolean,
    ): RdpNativeRequest = RdpNativeRequest.parse(
        mapOf(
            "schemaVersion" to 4,
            "requestId" to requestId,
            "targetHost" to host,
            "targetPort" to port,
            "username" to username,
            "domain" to domain,
            "gateway" to null,
            "certificateFingerprint" to fingerprint,
            "requiresNla" to true,
            "display" to mapOf(
                "width" to width,
                "height" to height,
                "desktopScaleFactor" to 100,
                "deviceScaleFactor" to 100,
                "externalDisplay" to false,
                "dynamicResize" to true,
            ),
            "keyboardLayout" to "us",
            "clipboardMode" to clipboardMode,
            "audio" to audio,
            "microphone" to microphone,
            "files" to false,
        ),
    )

    private fun awaitMicrophoneOpen(
        session: RdpFreeRdpSession,
        timeoutSeconds: Long,
    ): RdpMicrophoneCaptureObservation {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
        while (System.nanoTime() < deadline) {
            val observation = session.microphoneObservation()
            if (observation.deviceOpen && observation.state in setOf(
                RdpMicrophoneCaptureState.OPENED,
                RdpMicrophoneCaptureState.CAPTURED,
                RdpMicrophoneCaptureState.SENT,
            )) return observation
            assertFalse(observation.state in setOf(
                RdpMicrophoneCaptureState.CLOSED,
                RdpMicrophoneCaptureState.FAILED,
            ))
            Thread.sleep(25)
        }
        throw AssertionError("owned microphone capture did not open before arming")
    }

    private fun awaitMicrophoneHostEffect(
        context: Context,
        nonce: String,
        session: RdpFreeRdpSession,
        baseline: RdpMicrophoneCaptureObservation,
        timeoutSeconds: Long,
    ) {
        require(Regex("[0-9a-f]{64}").matches(nonce))
        val file = File(context.filesDir, "f62-owned-microphone-$nonce")
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
        try {
            while (System.nanoTime() < deadline) {
                val observation = session.microphoneObservation()
                if (file.exists()) {
                    val metadata = android.system.Os.lstat(file.absolutePath)
                    assertEquals(0x8000, metadata.st_mode and 0xF000)
                    assertEquals(0x180, metadata.st_mode and 0x1FF)
                    assertEquals(android.os.Process.myUid(), metadata.st_uid)
                    assertEquals(64L, metadata.st_size)
                    assertEquals(nonce, file.readText(Charsets.US_ASCII))
                    assertTrue(observation.deviceOpen)
                    assertTrue(observation.capturedCount > baseline.capturedCount)
                    assertTrue(observation.acceptedCount > baseline.acceptedCount)
                    assertTrue(observation.acceptedCount <= observation.capturedCount)
                    return
                }
                Thread.sleep(25)
            }
            throw AssertionError("owned host microphone tone was not observed")
        } finally {
            file.delete()
        }
    }

    private fun awaitRemoteAudio(
        session: RdpFreeRdpSession,
        baseline: RdpRemoteAudioObservation,
        timeoutSeconds: Long,
    ): RdpRemoteAudioObservation {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
        while (System.nanoTime() < deadline) {
            val observation = session.audioObservation()
            if (
                observation.state == RdpRemoteAudioState.PLAYING &&
                observation.deviceOpen &&
                observation.completedCount >= baseline.completedCount + 1L &&
                observation.acceptedCount >= observation.completedCount
            ) return observation
            Thread.sleep(25)
        }
        throw AssertionError("owned remote audio queue completion was not observed")
    }

    private fun awaitFrame(
        session: RdpFreeRdpSession,
        ready: ArrayBlockingQueue<Unit>,
        width: Int,
        height: Int,
        timeoutSeconds: Long,
    ): RdpNativeFrame {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
        while (true) {
            val remaining = deadline - System.nanoTime()
            assertTrue(
                "remote ${width}x$height frame callback",
                remaining > 0 && ready.poll(remaining, TimeUnit.NANOSECONDS) != null,
            )
            val frame = requireNotNull(session.pendingFrame)
            if (frame.width == width && frame.height == height) {
                return frame
            }
            assertTrue("intermediate frame acknowledgement", session.acknowledgeFrame(frame.sequence))
        }
    }

    private fun awaitInitialFrame(
        session: RdpFreeRdpSession,
        ready: ArrayBlockingQueue<Unit>,
        callbacks: BoundedFrameCallbacks,
        diagnostic: OwnedLifecycleDiagnostic,
        width: Int,
        height: Int,
        timeoutSeconds: Long,
    ): RdpNativeFrame {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
        var lastDimensions: Pair<Int, Int>? = null
        while (true) {
            if (session.phase == RdpJniPhase.FAILED || session.phase == RdpJniPhase.CANCELLED) {
                failInitialFrame(
                    InitialFrameFailureKind.TERMINAL,
                    session,
                    callbacks,
                    lastDimensions,
                    diagnostic,
                )
            }
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) {
                if (
                    session.phase == RdpJniPhase.FAILED ||
                    session.phase == RdpJniPhase.CANCELLED
                ) {
                    failInitialFrame(
                        InitialFrameFailureKind.TERMINAL,
                        session,
                        callbacks,
                        lastDimensions,
                        diagnostic,
                    )
                }
                val kind = when {
                    callbacks.count == 0 -> InitialFrameFailureKind.NO_CALLBACK
                    lastDimensions != null -> InitialFrameFailureKind.SIZE_MISMATCH
                    else -> InitialFrameFailureKind.STALLED_AFTER_CALLBACK
                }
                failInitialFrame(kind, session, callbacks, lastDimensions, diagnostic)
            }
            val token = ready.poll(
                minOf(remaining, TimeUnit.MILLISECONDS.toNanos(250)),
                TimeUnit.NANOSECONDS,
            ) ?: continue
            if (session.phase == RdpJniPhase.FAILED || session.phase == RdpJniPhase.CANCELLED) {
                failInitialFrame(
                    InitialFrameFailureKind.TERMINAL,
                    session,
                    callbacks,
                    lastDimensions,
                    diagnostic,
                )
            }
            val frame = session.pendingFrame
                ?: failInitialFrame(
                    InitialFrameFailureKind.STALLED_AFTER_CALLBACK,
                    session,
                    callbacks,
                    lastDimensions,
                    diagnostic,
                )
            lastDimensions = frame.width to frame.height
            if (frame.width == width && frame.height == height) return frame
            if (!session.acknowledgeFrame(frame.sequence)) {
                val kind = if (
                    session.phase == RdpJniPhase.FAILED ||
                    session.phase == RdpJniPhase.CANCELLED
                ) {
                    InitialFrameFailureKind.TERMINAL
                } else {
                    InitialFrameFailureKind.STALLED_AFTER_CALLBACK
                }
                failInitialFrame(kind, session, callbacks, lastDimensions, diagnostic)
            }
        }
    }

    private fun failInitialFrame(
        kind: InitialFrameFailureKind,
        session: RdpFreeRdpSession,
        callbacks: BoundedFrameCallbacks,
        lastDimensions: Pair<Int, Int>?,
        diagnostic: OwnedLifecycleDiagnostic,
    ): Nothing {
        val callbackSnapshot = callbacks.snapshot()
        val terminalPhase = session.phase
        val terminalCode = session.failureCode
        diagnostic.initialFrameFailure(
            kind,
            callbackSnapshot.first,
            callbackSnapshot.second,
            lastDimensions,
            terminalPhase,
            terminalCode,
        )
        val cause = AssertionError("owned initial frame wait did not complete")
        throw when (kind) {
            InitialFrameFailureKind.TERMINAL -> initialFrameTerminalFailure(
                terminalPhase,
                terminalCode,
                cause,
            )
            InitialFrameFailureKind.NO_CALLBACK -> RdpOwnedInitialFrameNoCallbackFailure(cause)
            InitialFrameFailureKind.SIZE_MISMATCH -> RdpOwnedInitialFrameSizeMismatchFailure(cause)
            InitialFrameFailureKind.STALLED_AFTER_CALLBACK ->
                RdpOwnedInitialFrameStalledAfterCallbackFailure(cause)
        }
    }

    private fun assertRenderedPixels(frame: RdpNativeFrame, width: Int, height: Int) {
        val pixels = frame.pixels.duplicate()
        var observedPixel = false
        while (pixels.hasRemaining()) {
            if (pixels.get().toInt() != 0) {
                observedPixel = true
                break
            }
        }
        assertTrue("remote ${width}x$height framebuffer contains rendered pixels", observedPixel)
    }

    private fun awaitChangedPixelFrame(
        session: RdpFreeRdpSession,
        ready: ArrayBlockingQueue<Unit>,
        width: Int,
        height: Int,
        previous: ByteArray,
        timeoutSeconds: Long,
    ): RdpNativeFrame {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
        while (true) {
            val remaining = deadline - System.nanoTime()
            assertTrue(
                "clipboard-causal framebuffer callback",
                remaining > 0 && ready.poll(remaining, TimeUnit.NANOSECONDS) != null,
            )
            val frame = requireNotNull(session.pendingFrame)
            if (frame.width == width && frame.height == height && !firstPixel(frame).contentEquals(previous)) {
                return frame
            }
            assertTrue("intermediate clipboard frame acknowledgement", session.acknowledgeFrame(frame.sequence))
        }
    }

    private fun firstPixel(frame: RdpNativeFrame): ByteArray {
        val pixels = frame.pixels.duplicate()
        val value = ByteArray(4)
        pixels.get(value)
        return value
    }

    private fun android.os.Bundle.required(key: String): String =
        getString(key)?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("Missing instrumented acceptance argument: $key")

    private fun assertConnectionInfoParses(context: Context, uri: android.net.Uri) {
        val session = GlobalApp.createSession(uri, context)
        try {
            assertTrue(
                "pinned FreeRDP accepts the packaged connection URI",
                LibFreeRDP.setConnectionInfo(context, session.instance, uri),
            )
        } finally {
            GlobalApp.freeSession(session.instance)
        }
    }

    private fun assertDiagnosticFailuresAreSecondary() {
        val retained = "testInitialization"
        val failing = OwnedLifecycleDiagnostic(object : LifecycleStorage {
            override fun write(stage: String) {
                check(retained == "testInitialization")
                throw java.io.IOException("owned diagnostic write unavailable")
            }

            override fun remove() {
                check(retained == "testInitialization")
                throw SecurityException("owned diagnostic cleanup unavailable")
            }
        })
        failing.enter("providerInspection")
        failing.remove()
        assertEquals("testInitialization", retained)
    }
}

internal interface LifecycleStorage {
    fun write(stage: String)
    fun remove()
}

internal interface EffectControlStorage {
    fun write(phase: String, record: ByteArray)
    fun remove()
}

internal class AtomicEffectControlStorage(
    context: Context,
    nonce: String,
) : EffectControlStorage {
    private val files = OWNED_EFFECT_CONTROL_PHASES.associateWith { phase ->
        AtomicFile(File(context.filesDir, "f62-owned-arm-$nonce-$phase"))
    }

    override fun write(phase: String, record: ByteArray) {
        val file = checkNotNull(files[phase])
        check(!file.baseFile.exists())
        var output: FileOutputStream? = null
        try {
            val stream = file.startWrite()
            output = stream
            stream.write(record)
            stream.fd.sync()
            file.finishWrite(stream)
            output = null
        } catch (failure: Exception) {
            output?.let { stream ->
                runCatching { file.failWrite(stream) }
            }
            throw failure
        }
    }

    override fun remove() = files.values.forEach { it.delete() }
}

internal class OwnedEffectControl(
    private val storage: EffectControlStorage,
    private val nonce: String,
    private val sourceSha256: String,
) {
    private var accepted = 0

    init {
        require(Regex("[0-9a-f]{64}").matches(nonce))
        require(Regex("[0-9a-f]{64}").matches(sourceSha256))
    }

    fun armAudio() = arm("audio")

    fun armMicrophone() = arm("microphone")

    fun remove() = storage.remove()

    private fun arm(phase: String) {
        check(accepted < OWNED_EFFECT_CONTROL_PHASES.size)
        check(OWNED_EFFECT_CONTROL_PHASES[accepted] == phase)
        val phaseCode = checkNotNull(OWNED_EFFECT_CONTROL_CODES[phase])
        val record = buildString(OWNED_EFFECT_CONTROL_BYTES) {
            append("LRNCTL01")
            append(phaseCode)
            append(nonce)
            append(sourceSha256)
            append(OWNED_EFFECT_CONTROL_TEST_DIGEST)
        }.encodeToByteArray()
        check(record.size == OWNED_EFFECT_CONTROL_BYTES)
        storage.write(phase, record)
        accepted += 1
    }
}

internal class AtomicLifecycleStorage(context: Context, nonce: String) : LifecycleStorage {
    private val file: AtomicFile

    init {
        require(Regex("[0-9a-f]{64}").matches(nonce))
        file = AtomicFile(File(context.filesDir, "f62-owned-stage-$nonce"))
    }

    override fun write(stage: String) {
        var output: FileOutputStream? = null
        try {
            val stream = file.startWrite()
            output = stream
            stream.write(stage.encodeToByteArray())
            stream.fd.sync()
            file.finishWrite(stream)
            output = null
        } catch (failure: Exception) {
            output?.let { stream ->
                runCatching { file.failWrite(stream) }
            }
            throw failure
        }
    }

    override fun remove() = file.delete()
}

internal class OwnedLifecycleDiagnostic(
    private val storage: LifecycleStorage,
    private val entered: (String) -> Unit = {},
) {
    private var failedOpenMarker: Pair<String, String>? = null

    fun enter(stage: String) {
        require(stage in OWNED_LIFECYCLE_STAGES)
        entered(stage)
        runCatching { storage.write(stage) }
    }

    fun remove() {
        runCatching { storage.remove() }
    }

    fun bodyFailure(stage: String, throwableClass: String) {
        val open = failedOpenMarker.takeIf {
            it?.first == stage &&
                throwableClass == "com.ersingundem.larenor.rdp.RdpNativeFailure"
        }
        failedOpenMarker = null
        runCatching { storage.write(open?.second ?: bodyFailureMarker(stage, throwableClass)) }
    }

    fun openFailure(
        stage: String,
        safeCode: String,
        snapshot: RdpPackagedOpenDiagnosticSnapshot,
    ) {
        if (stage !in setOf("firstSessionOpen", "secondSessionOpen") ||
            safeCode !in setOf("connectionFailed", "engineUnavailable")) return
        val bits = listOf(
            snapshot.connectionInfoParsed, snapshot.connectAccepted,
            snapshot.certificateAccepted, snapshot.authenticatedConnectionSucceeded,
            snapshot.displayCapsObserved, snapshot.initialLayoutAccepted,
            snapshot.securityPublished,
        ).joinToString("") { if (it) "1" else "0" }
        val marker = listOf(
            "openFailure", "v1", stage, safeCode, bits,
            snapshot.terminal.wireValue, if (snapshot.timeout) "1" else "0",
        ).joinToString("|")
        if (marker.length <= 128 && failedOpenMarker == null) {
            failedOpenMarker = stage to marker
        }
    }

    fun initialFrameFailure(
        kind: InitialFrameFailureKind,
        callbackCount: Int,
        callbackCountCapped: Boolean,
        lastDimensions: Pair<Int, Int>?,
        phase: RdpJniPhase,
        failureCode: String?,
    ) {
        val phaseValue = when (phase) {
            RdpJniPhase.ACTIVE -> "active"
            RdpJniPhase.AWAITING_FRAME_ACK -> "awaitingFrameAck"
            RdpJniPhase.FAILED -> "failed"
            RdpJniPhase.CANCELLED -> "cancelled"
            RdpJniPhase.CONNECTING -> return
        }
        val safeCode = failureCode?.takeIf {
            it in setOf(
                "connectionFailed", "frameBackpressure",
                "framebufferUnavailable", "staleSession",
            )
        }
        if (phase == RdpJniPhase.FAILED && safeCode == null) return
        if (phase == RdpJniPhase.CANCELLED && failureCode != null) return
        if (
            phase in setOf(RdpJniPhase.ACTIVE, RdpJniPhase.AWAITING_FRAME_ACK) &&
            failureCode != null
        ) return
        val width = lastDimensions?.first?.toString() ?: "-"
        val height = lastDimensions?.second?.toString() ?: "-"
        val marker = listOf(
            "initialFrameWait",
            "v1",
            kind.wire,
            callbackCount.coerceIn(0, BoundedFrameCallbacks.MAX).toString(),
            if (callbackCountCapped) "1" else "0",
            width,
            height,
            phaseValue,
            safeCode ?: "-",
        ).joinToString("|")
        if (marker.length <= 128) runCatching { storage.write(marker) }
    }

}

private val OWNED_LIFECYCLE_STAGES = setOf(
    "testInitialization",
    "connectionValidation",
    "runtimeValidation",
    "providerInspection",
    "firstSessionOpen",
    "firstSecurityWait",
    "initialFrameWait",
    "audioEffectWait",
    "microphoneOpenWait",
    "microphoneEffectWait",
    "keySubmission",
    "resizeSubmission",
    "resizedFrameWait",
    "clipboardSubmission",
    "clipboardEffectWait",
    "firstClose",
    "firstClosedValidation",
    "secondSessionOpen",
    "secondSecurityWait",
    "secondFrameWait",
    "disabledClipboardCheck",
    "secondClose",
    "credentialValidation",
    "complete",
)

private val OWNED_EFFECT_CONTROL_PHASES = listOf("audio", "microphone")
private val OWNED_EFFECT_CONTROL_CODES = mapOf(
    "audio" to "AUDARM01",
    "microphone" to "MICARM01",
)
private const val OWNED_EFFECT_CONTROL_TEST_DIGEST =
    "784cd21e527c4b3bac1eef254097cdaf5cc3ef8d4f41d4b4473c61724bb69fbb"
private const val OWNED_EFFECT_CONTROL_BYTES = 208

private val OWNED_BODY_THROWABLE_CLASSES = setOf(
    "com.ersingundem.larenor.rdp.RdpNativeFailure",
    "java.lang.AssertionError",
    "java.lang.ClassNotFoundException",
    "java.lang.ExceptionInInitializerError",
    "java.lang.IllegalStateException",
    "java.lang.InterruptedException",
    "java.lang.NoClassDefFoundError",
    "java.lang.NullPointerException",
    "java.lang.RuntimeException",
    "java.lang.SecurityException",
    "java.lang.UnsupportedOperationException",
    "java.lang.UnsatisfiedLinkError",
    "java.util.concurrent.TimeoutException",
    "kotlin.KotlinNullPointerException",
    "org.junit.ComparisonFailure",
    "org.junit.runners.model.TestTimedOutException",
    "unclassified",
)

internal class RdpOwnedTestBodyFailure(
    val lifecycleStage: String,
    val throwableClass: String,
) : AssertionError("stage=$lifecycleStage;throwable=$throwableClass") {
    init {
        require(lifecycleStage in OWNED_LIFECYCLE_STAGES)
        require(throwableClass in OWNED_BODY_THROWABLE_CLASSES)
    }
}

internal fun bodyFailureMarker(stage: String, throwableClass: String): String {
    require(stage in OWNED_LIFECYCLE_STAGES)
    require(throwableClass in OWNED_BODY_THROWABLE_CLASSES)
    return "bodyFailure|v1|$stage|$throwableClass"
}

internal fun diagnoseOwnedTestBody(
    body: (
        entered: (String) -> Unit,
        registerFailureMarker: ((String, String) -> Unit) -> Unit,
    ) -> Unit,
) {
    var lifecycleStage = "testInitialization"
    var failureMarker: ((String, String) -> Unit)? = null
    val entered: (String) -> Unit = { stage ->
        require(stage in OWNED_LIFECYCLE_STAGES)
        lifecycleStage = stage
    }
    val registerFailureMarker: (((String, String) -> Unit) -> Unit) = { marker ->
        check(failureMarker == null)
        failureMarker = marker
    }
    fun classified(cause: Throwable): RdpOwnedTestBodyFailure {
        val failure = ownedTestBodyFailure(lifecycleStage, cause)
        runCatching {
            failureMarker?.invoke(failure.lifecycleStage, failure.throwableClass)
        }
        return failure
    }
    try {
        body(entered, registerFailureMarker)
    } catch (cause: RdpOwnedClassifiedFailure) {
        throw cause
    } catch (cause: InterruptedException) {
        Thread.currentThread().interrupt()
        throw classified(cause)
    } catch (cause: AssertionError) {
        throw classified(cause)
    } catch (cause: Exception) {
        throw classified(cause)
    } catch (cause: LinkageError) {
        throw classified(cause)
    }
}

private fun ownedTestBodyFailure(
    lifecycleStage: String,
    cause: Throwable,
): RdpOwnedTestBodyFailure {
    val exactClass = cause::class.java.name.takeIf {
        it in OWNED_BODY_THROWABLE_CLASSES
    } ?: "unclassified"
    return RdpOwnedTestBodyFailure(lifecycleStage, exactClass)
}

internal enum class InitialFrameFailureKind(val wire: String) {
    TERMINAL("terminal"),
    NO_CALLBACK("noCallback"),
    SIZE_MISMATCH("sizeMismatch"),
    STALLED_AFTER_CALLBACK("stalledAfterCallback"),
}

internal class BoundedFrameCallbacks {
    private val countValue = AtomicInteger(0)
    private val overflow = AtomicBoolean(false)

    val count: Int get() = countValue.get()

    fun snapshot(): Pair<Int, Boolean> {
        while (true) {
            val before = countValue.get()
            val capped = before >= MAX || overflow.get()
            if (before == countValue.get()) return before to capped
        }
    }

    fun observed() {
        while (true) {
            val current = countValue.get()
            if (current >= MAX) {
                overflow.set(true)
                return
            }
            if (countValue.compareAndSet(current, current + 1)) return
        }
    }

    companion object {
        const val MAX = 4096
    }
}

private inline fun <T> diagnoseStage(
    failure: (Throwable) -> AssertionError,
    body: () -> T,
): T = try {
    body()
} catch (cause: AssertionError) {
    throw failure(cause)
} catch (cause: RuntimeException) {
    throw failure(cause)
} catch (cause: InterruptedException) {
    Thread.currentThread().interrupt()
    throw failure(cause)
}

private open class RdpOwnedClassifiedFailure(cause: Throwable) : AssertionError(cause)

private class RdpOwnedResizedFrameWaitFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFrameTerminalFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFrameConnectionFailed(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFrameBackpressureFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFramebufferUnavailable(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFrameStaleSession(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFrameCancelled(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFrameNoCallbackFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFrameSizeMismatchFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedInitialFrameStalledAfterCallbackFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedResizedFramePixelsFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedResizedFrameAckFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedCleanCloseFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedCredentialClearFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedClientDispSubmissionFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedClipboardSubmissionFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedClipboardEffectWaitFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)
private class RdpOwnedDisabledClipboardFailure(cause: Throwable) : RdpOwnedClassifiedFailure(cause)

internal fun initialFrameTerminalFailure(
    phase: RdpJniPhase,
    failureCode: String?,
    cause: Throwable,
): AssertionError = when (phase to failureCode) {
    RdpJniPhase.FAILED to "connectionFailed" ->
        RdpOwnedInitialFrameConnectionFailed(cause)
    RdpJniPhase.FAILED to "frameBackpressure" ->
        RdpOwnedInitialFrameBackpressureFailure(cause)
    RdpJniPhase.FAILED to "framebufferUnavailable" ->
        RdpOwnedInitialFramebufferUnavailable(cause)
    RdpJniPhase.FAILED to "staleSession" ->
        RdpOwnedInitialFrameStaleSession(cause)
    RdpJniPhase.CANCELLED to null -> RdpOwnedInitialFrameCancelled(cause)
    else -> RdpOwnedInitialFrameTerminalFailure(cause)
}
