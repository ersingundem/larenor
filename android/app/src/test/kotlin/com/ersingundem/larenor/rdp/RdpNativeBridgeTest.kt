package com.ersingundem.larenor.rdp

import android.app.Application
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpNativeBridgeTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit
    }

    private class Result : MethodChannel.Result {
        @Volatile var value: Any? = null
        @Volatile var error: String? = null
        @Volatile var done = false
        override fun success(result: Any?) { value = result; done = true }
        override fun error(code: String, message: String?, details: Any?) { error = code; done = true }
        override fun notImplemented() { error = "missing"; done = true }
    }

    private class Sink : EventChannel.EventSink {
        override fun success(event: Any?) = Unit
        override fun error(code: String, message: String?, details: Any?) = Unit
        override fun endOfStream() = Unit
    }

    @Test
    fun blockedOpenRejectsSecondNetworkJobAndClosesSecretBuffers() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val creates = AtomicInteger()
        val capturedPassword = AtomicReference<CharArray>()
        val runtime = object : RdpJniRuntime {
            override fun identity() = RdpFreeRdpIdentity(
                RdpFreeRdpPackage.VERSION,
                RdpFreeRdpPackage.SOURCE_COMMIT,
                RdpFreeRdpPackage.SOURCE_SHA256,
                "x86_64",
                1,
                emptySet(),
            )

            override fun capabilities() = availableCapabilities()

            override fun create(
                request: RdpNativeRequest,
                plan: RdpNativeNegotiated,
                listener: RdpJniOperation.Listener,
            ): RdpJniOperation {
                creates.incrementAndGet()
                return object : RdpJniOperation {
                    override fun start(password: CharArray, gatewayPassword: CharArray?): Boolean {
                        capturedPassword.set(password)
                        started.countDown()
                        release.await(2, TimeUnit.SECONDS)
                        return true
                    }
                    override fun input(sequence: Long, event: RdpJniInput) = true
                    override fun resize(sequence: Long, display: RdpNativeDisplay) = true
                    override fun acknowledgeFrame(sequence: Long) = true
                    override fun close() = Unit
                    override fun detach() = Unit
                }
            }
        }
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().visible()
            .windowFocusChanged(true)
        val bridge = RdpNativeBridge(activity.get(), Messenger(), runtime)
        try {
            bridge.setResumed(true)
            bridge.onListen(REQUEST_ID, Sink())
            val activated = Result()
            bridge.onMethodCall(MethodCall("activate", mapOf("requestId" to REQUEST_ID)), activated)
            assertNull(activated.error)

            val password = "secret".encodeToByteArray()
            val gatewayPassword = ByteArray(0)
            val opening = Result()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "request" to request(), "requestId" to REQUEST_ID,
                "password" to password, "gatewayPassword" to gatewayPassword,
            )), opening)
            assertTrue(started.await(1, TimeUnit.SECONDS))
            assertTrue(password.all { it == 0.toByte() })
            assertTrue(gatewayPassword.all { it == 0.toByte() })

            val competing = Result()
            bridge.onMethodCall(MethodCall("inspect", mapOf(
                "targetHost" to "fixture.invalid", "targetPort" to 3389, "username" to "fixture",
            )), competing)
            assertEquals("busy", competing.error)
            assertEquals(1, creates.get())

            release.countDown()
            await(opening)
            assertNull(opening.error)
            assertTrue(capturedPassword.get().all { it == '\u0000' })
        } finally {
            release.countDown()
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    private fun await(result: Result) {
        repeat(400) {
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            if (result.done) return
            Thread.sleep(5)
        }
        throw AssertionError("Timed out waiting for RDP bridge result")
    }

    private fun availableCapabilities() = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "availability" to "available",
        "engineRevision" to RdpFreeRdpPackage.ENGINE_REVISION,
        "security" to mapOf(
            "tls" to true, "certificatePinning" to true, "nla" to true, "rdGateway" to false,
        ),
        "display" to mapOf(
            "dynamicResolution" to true, "externalDisplay" to true,
            "maxWidth" to 4096, "maxHeight" to 2160, "maxDpi" to 480,
        ),
        "input" to mapOf("pointer" to true, "keyboard" to true, "ime" to true),
        "channels" to mapOf(
            "clipboardModes" to listOf("disabled"), "audio" to false, "files" to false,
        ),
    )

    private fun request() = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to REQUEST_ID,
        "targetHost" to "fixture.invalid",
        "targetPort" to 3389,
        "username" to "fixture",
        "domain" to "TEST",
        "gateway" to null,
        "certificateFingerprint" to PIN,
        "requiresNla" to true,
        "display" to mapOf(
            "width" to 1280, "height" to 800, "dpi" to 180,
            "externalDisplay" to false, "dynamicResize" to true,
        ),
        "keyboardLayout" to "turkishQ",
        "clipboardMode" to "disabled",
        "audio" to false,
        "files" to false,
    )

    companion object {
        private const val REQUEST_ID = "11111111-1111-4111-8111-111111111111"
        private const val PIN = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    }
}
