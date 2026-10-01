package com.ersingundem.larenor.rdp

import android.content.Context
import android.util.AtomicFile
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime
import com.ersingundem.larenor.rdp.packaged.packagedConnectionUri
import com.freerdp.freerdpcore.application.GlobalApp
import com.freerdp.freerdpcore.services.LibFreeRDP
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun nlaShadowBaselineProvesPinnedFramesKeyEffectResizeAndCleanClose() {
        val arguments = InstrumentationRegistry.getArguments()
        val diagnosticNonce = arguments.required("rdpDiagnosticNonce")
        val context = ApplicationProvider.getApplicationContext<Context>()
        val diagnostic = OwnedLifecycleDiagnostic(
            AtomicLifecycleStorage(context, diagnosticNonce),
        )
        diagnostic.enter("testInitialization")

        val host = arguments.required("rdpHost")
        val port = arguments.required("rdpPort").toInt()
        val username = arguments.required("rdpUsername")
        val domain = arguments.required("rdpDomain")
        val passwordValue = arguments.required("rdpPassword")
        assertDiagnosticFailuresAreSecondary()
        val runtime = RdpPackagedRuntime(context)

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
        assertTrue(!capabilities.ime)
        assertTrue(RdpClipboardMode.CLIENT_TO_REMOTE in capabilities.clipboardModes)
        assertTrue(!capabilities.audio && !capabilities.files)

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
        )
        val security = CountDownLatch(1)
        val frameReady = ArrayBlockingQueue<Unit>(8)
        val closed = CountDownLatch(1)
        val observer = object : RdpNativeSessionObserver {
            override fun onSecurity() = security.countDown()
            override fun onFrame() {
                frameReady.offer(Unit)
            }
            override fun onClosed(code: String?) = closed.countDown()
        }
        val password = passwordValue.toCharArray()
        diagnostic.enter("firstSessionOpen")
        val session = RdpNativeAdapter(RdpFreeRdpBackend(runtime)).open(
            request,
            RdpNativeSecrets.take(password, null),
            observer,
        ) as RdpFreeRdpSession

        var firstBodyCompleted = false
        try {
            diagnostic.enter("firstSecurityWait")
            assertTrue("native security callback", security.await(10, TimeUnit.SECONDS))
            assertTrue(
                "session entered the active frame lifecycle",
                session.phase == RdpJniPhase.ACTIVE ||
                    session.phase == RdpJniPhase.AWAITING_FRAME_ACK,
            )
            diagnostic.enter("initialFrameWait")
            val initial = awaitFrame(session, frameReady, 1280, 800, 30)
            assertRenderedPixels(initial, 1280, 800)
            assertEquals(180, initial.dpi)
            assertTrue(session.acknowledgeFrame(initial.sequence))

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
                    session.resize(3, RdpNativeDisplay(1024, 768, 180, false, true)),
                )
            }

            diagnostic.enter("resizedFrameWait")
            val resized = diagnoseStage(::RdpOwnedResizedFrameWaitFailure) {
                awaitFrame(session, frameReady, 1024, 768, 30)
            }
            diagnoseStage(::RdpOwnedResizedFramePixelsFailure) {
                assertRenderedPixels(resized, 1024, 768)
                assertEquals(180, resized.dpi)
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
        val disabled = RdpNativeAdapter(RdpFreeRdpBackend(runtime)).open(
            disabledRequest,
            RdpNativeSecrets.take(disabledPassword, null),
            disabledObserver,
        ) as RdpFreeRdpSession
        var secondBodyCompleted = false
        try {
            diagnostic.enter("secondSecurityWait")
            assertTrue(
                "disabled lifetime native security callback",
                disabledSecurity.await(10, TimeUnit.SECONDS),
            )
            diagnostic.enter("secondFrameWait")
            val frame = awaitFrame(disabled, disabledFrames, 1024, 768, 30)
            assertRenderedPixels(frame, 1024, 768)
            assertTrue(disabled.acknowledgeFrame(frame.sequence))
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
        diagnostic.remove()
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
    ): RdpNativeRequest = RdpNativeRequest.parse(
        mapOf(
            "schemaVersion" to 1,
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
                "dpi" to 180,
                "externalDisplay" to false,
                "dynamicResize" to true,
            ),
            "keyboardLayout" to "us",
            "clipboardMode" to clipboardMode,
            "audio" to false,
            "files" to false,
        ),
    )

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

internal class OwnedLifecycleDiagnostic(private val storage: LifecycleStorage) {
    fun enter(stage: String) {
        require(stage in STAGES)
        runCatching { storage.write(stage) }
    }

    fun remove() {
        runCatching { storage.remove() }
    }

    private companion object {
        val STAGES = setOf(
            "testInitialization",
            "connectionValidation",
            "runtimeValidation",
            "providerInspection",
            "firstSessionOpen",
            "firstSecurityWait",
            "initialFrameWait",
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

private class RdpOwnedResizedFrameWaitFailure(cause: Throwable) : AssertionError(cause)
private class RdpOwnedResizedFramePixelsFailure(cause: Throwable) : AssertionError(cause)
private class RdpOwnedResizedFrameAckFailure(cause: Throwable) : AssertionError(cause)
private class RdpOwnedCleanCloseFailure(cause: Throwable) : AssertionError(cause)
private class RdpOwnedCredentialClearFailure(cause: Throwable) : AssertionError(cause)
private class RdpOwnedClientDispSubmissionFailure(cause: Throwable) : AssertionError(cause)
private class RdpOwnedClipboardSubmissionFailure(cause: Throwable) : AssertionError(cause)
private class RdpOwnedClipboardEffectWaitFailure(cause: Throwable) : AssertionError(cause)
private class RdpOwnedDisabledClipboardFailure(cause: Throwable) : AssertionError(cause)
