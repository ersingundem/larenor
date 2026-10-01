package com.ersingundem.larenor.rdp

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime
import com.ersingundem.larenor.rdp.packaged.packagedConnectionUri
import com.freerdp.freerdpcore.application.GlobalApp
import com.freerdp.freerdpcore.services.LibFreeRDP
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
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
        val host = arguments.required("rdpHost")
        val port = arguments.required("rdpPort").toInt()
        val username = arguments.required("rdpUsername")
        val domain = arguments.required("rdpDomain")
        val password = arguments.required("rdpPassword").toCharArray()
        val context = ApplicationProvider.getApplicationContext<Context>()
        val runtime = RdpPackagedRuntime(context)

        assertConnectionInfoParses(
            context,
            packagedConnectionUri(host, port, username, 1280, 800, true),
        )
        assertConnectionInfoParses(
            context,
            packagedConnectionUri(host, port, username, 1280, 800, false),
        )

        assertTrue(RdpFreeRdpPackage.verify(runtime.identity()))
        val capabilities = RdpNativeCapabilities.parse(runtime.capabilities())
        assertTrue(capabilities.canConnect)
        assertTrue(capabilities.nla)
        assertTrue(!capabilities.ime)
        assertTrue(RdpClipboardMode.CLIENT_TO_REMOTE in capabilities.clipboardModes)
        assertTrue(!capabilities.audio && !capabilities.files)

        val inspected = runtime.inspect(host, port, username)
        assertTrue(inspected.clientRequiresNla)
        assertEquals("TLSv1.2", inspected.minimumTlsPolicy)
        assertEquals(50, inspected.certificateFingerprint.length)
        assertTrue(Regex("SHA256:[A-Za-z0-9+/]{43}").matches(inspected.certificateFingerprint))

        val request = RdpNativeRequest.parse(
            mapOf(
                "schemaVersion" to 1,
                "requestId" to "62726270-0000-4000-8000-000000000001",
                "targetHost" to host,
                "targetPort" to port,
                "username" to username,
                "domain" to domain,
                "gateway" to null,
                "certificateFingerprint" to inspected.certificateFingerprint,
                "requiresNla" to true,
                "display" to mapOf(
                    "width" to 1280,
                    "height" to 800,
                    "dpi" to 180,
                    "externalDisplay" to false,
                    // Required for accepting a server-originated DesktopResize.
                    // This baseline never invokes session.resize/client DISP.
                    "dynamicResize" to true,
                ),
                "keyboardLayout" to "us",
                "clipboardMode" to "disabled",
                "audio" to false,
                "files" to false,
            ),
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
        val session = RdpNativeAdapter(RdpFreeRdpBackend(runtime)).open(
            request,
            RdpNativeSecrets.take(password, null),
            observer,
        ) as RdpFreeRdpSession

        try {
            assertTrue("native security callback", security.await(10, TimeUnit.SECONDS))
            assertTrue(
                "session entered the active frame lifecycle",
                session.phase == RdpJniPhase.ACTIVE ||
                    session.phase == RdpJniPhase.AWAITING_FRAME_ACK,
            )
            val initial = awaitFrame(session, frameReady, 1280, 800, 30)
            assertRenderedPixels(initial, 1280, 800)
            assertEquals(180, initial.dpi)
            assertTrue(session.acknowledgeFrame(initial.sequence))

            // The host runner observes this exact software HID key pair through XI2,
            // then changes the owned Xorg output to 1024x768. No clipboard, IME or
            // client DISP claim is part of this shadow-server baseline.
            assertTrue(session.key(1, 0x70004, true))
            assertTrue(session.key(2, 0x70004, false))

            val resized = diagnoseStage(::RdpOwnedResizedFrameWaitFailure) {
                awaitFrame(session, frameReady, 1024, 768, 30)
            }
            diagnoseStage(::RdpOwnedResizedFramePixelsFailure) {
                assertRenderedPixels(resized, 1024, 768)
                assertEquals(180, resized.dpi)
            }
            diagnoseStage(::RdpOwnedResizedFrameAckFailure) {
                assertTrue(session.acknowledgeFrame(resized.sequence))
            }
        } finally {
            diagnoseStage(::RdpOwnedCleanCloseFailure) {
                session.close()
            }
        }
        diagnoseStage(::RdpOwnedCleanCloseFailure) {
            assertEquals(RdpJniPhase.CANCELLED, session.phase)
            assertTrue("session close callback", closed.await(5, TimeUnit.SECONDS))
        }
        diagnoseStage(::RdpOwnedCredentialClearFailure) {
            assertTrue(password.all { it == '\u0000' })
        }
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
