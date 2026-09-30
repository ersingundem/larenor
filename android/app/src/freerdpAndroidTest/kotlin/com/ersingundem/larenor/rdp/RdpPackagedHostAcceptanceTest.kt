package com.ersingundem.larenor.rdp

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime
import com.ersingundem.larenor.rdp.packaged.packagedConnectionUri
import com.freerdp.freerdpcore.application.GlobalApp
import com.freerdp.freerdpcore.services.LibFreeRDP
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
    fun nlaHostDeliversPinnedFrameInputResizeClipboardAndCleanClose() {
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
        assertTrue(capabilities.dynamicResolution)
        assertTrue(RdpClipboardMode.CLIENT_TO_REMOTE in capabilities.clipboardModes)
        assertTrue(!capabilities.audio && !capabilities.files)

        val inspected = runtime.inspect(host, port, username)
        assertTrue(inspected.nla)
        assertEquals("TLSv1.2", inspected.minimumTlsProtocol)
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
                    "dynamicResize" to true,
                ),
                "keyboardLayout" to "us",
                "clipboardMode" to "clientToRemote",
                "audio" to false,
                "files" to false,
            ),
        )
        val security = CountDownLatch(1)
        val frameReady = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val observer = object : RdpNativeSessionObserver {
            override fun onSecurity() = security.countDown()
            override fun onFrame() = frameReady.countDown()
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
            assertTrue("first remote frame", frameReady.await(30, TimeUnit.SECONDS))
            val frame = requireNotNull(session.pendingFrame)
            assertEquals(1280, frame.width)
            assertEquals(800, frame.height)
            assertEquals(180, frame.dpi)
            val pixels = frame.pixels.duplicate()
            var observedPixel = false
            while (pixels.hasRemaining()) {
                if (pixels.get().toInt() != 0) {
                    observedPixel = true
                    break
                }
            }
            assertTrue("remote framebuffer contains rendered pixels", observedPixel)
            assertTrue(session.acknowledgeFrame(frame.sequence))

            assertTrue(session.pointer(1, 0.5, 0.5, 0))
            assertTrue(session.key(2, 0x70004, true))
            assertTrue(session.key(3, 0x70004, false))
            assertTrue(session.ime(4, "Larenor"))
            val clipboard = "Larenor RDP acceptance".toByteArray()
            assertTrue(session.channel(5, RdpJniChannel.CLIPBOARD, clipboard))
            assertTrue("clipboard payload is zeroized", clipboard.all { it == 0.toByte() })
            assertTrue(
                session.resize(
                    6,
                    RdpNativeDisplay(1024, 768, 220, true, true),
                ),
            )
        } finally {
            session.close()
        }
        assertEquals(RdpJniPhase.CANCELLED, session.phase)
        assertTrue("session close callback", closed.await(5, TimeUnit.SECONDS))
        assertTrue(password.all { it == '\u0000' })
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
