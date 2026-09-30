package com.ersingundem.larenor.speech

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.pm.PackageManager
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.time.Duration
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalSpeechBridgeTest {
    private class Reply {
        var value: Any? = null
        var error: String? = null
        var replies = 0
    }

    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            handlers[channel] = handler
        }

        fun call(method: String, arguments: Any? = null): Reply {
            val result = Reply()
            val codec = StandardMethodCodec.INSTANCE
            val request = codec.encodeMethodCall(MethodCall(method, arguments)).also { it.flip() }
            handlers[LocalSpeechBridge.CHANNEL]!!.onMessage(request) { envelope ->
                result.replies++
                envelope!!.flip()
                try {
                    result.value = codec.decodeEnvelope(envelope)
                } catch (error: FlutterException) {
                    result.error = error.code
                    assertNull(error.details)
                    assertFalse(error.message.orEmpty().contains("transcript"))
                }
            }
            return result
        }
    }

    private class Host : LocalSpeechHost {
        var available = true
        var stops = 0
        val recognitions = mutableListOf<String>()
        val speeches = mutableListOf<Pair<String, String>>()
        var recognition: ((String?, String?) -> Unit)? = null
        var speech: ((String?) -> Unit)? = null
        override fun available() = available
        override fun recognize(locale: String, completed: (String?, String?) -> Unit) {
            recognitions += locale
            recognition = completed
        }
        override fun speak(locale: String, text: String, completed: (String?) -> Unit) {
            speeches += locale to text
            speech = completed
        }
        override fun stop() { stops++ }
    }

    private fun activity() = Robolectric.buildActivity(Activity::class.java).setup().visible()

    @Test fun probeIsPassiveAndPermissionNeverStartsRecognition() {
        val controller = activity()
        val activity = controller.get()
        val messenger = Messenger()
        val host = Host()
        var focused = true
        val bridge = LocalSpeechBridge(activity, messenger, host) { focused }
        try {
            bridge.setResumed(true)
            val probe = messenger.call("probe")
            assertEquals(mapOf(
                "schemaVersion" to 1,
                "onDeviceAvailable" to true,
                "microphoneGranted" to false,
            ), probe.value)
            assertTrue(host.recognitions.isEmpty())
            assertTrue(host.speeches.isEmpty())

            val permission = messenger.call("requestPermission")
            assertEquals(0, permission.replies)
            val request = Shadows.shadowOf(activity).lastRequestedPermission
            assertArrayEquals(arrayOf(Manifest.permission.RECORD_AUDIO), request.requestedPermissions)
            assertEquals(LocalSpeechBridge.REQUEST_MICROPHONE, request.requestCode)

            // Losing focus to the Android permission prompt does not forge a
            // recognition gesture. The caller must tap listen again.
            focused = false
            bridge.windowChanged()
            assertTrue(bridge.onRequestPermissionsResult(
                LocalSpeechBridge.REQUEST_MICROPHONE,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                intArrayOf(PackageManager.PERMISSION_GRANTED),
            ))
            assertEquals(true, permission.value)
            assertTrue(host.recognitions.isEmpty())
            assertEquals(1, permission.replies)
        } finally {
            bridge.dispose()
            controller.pause().stop().destroy()
        }
    }

    @Test fun lifecycleCancellationAndDeadlineRejectEveryLateCallbackOnce() {
        val controller = activity()
        val activity = controller.get()
        Shadows.shadowOf(activity.application).grantPermissions(Manifest.permission.RECORD_AUDIO)
        val messenger = Messenger()
        val host = Host()
        val bridge = LocalSpeechBridge(activity, messenger, host) { true }
        try {
            bridge.setResumed(true)
            val first = messenger.call("recognize", mapOf("locale" to "tr-TR"))
            assertEquals(listOf("tr-TR"), host.recognitions)
            val firstCallback = host.recognition!!
            bridge.setResumed(false)
            assertEquals("cancelled", first.error)
            assertEquals(1, first.replies)
            firstCallback("gecikmiş özel metin", null)
            assertNull(first.value)
            assertEquals(1, first.replies)

            bridge.setResumed(true)
            val second = messenger.call("recognize", mapOf("locale" to "en-US"))
            val secondCallback = host.recognition!!
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(30))
            assertEquals("timeout", second.error)
            assertEquals(1, second.replies)
            secondCallback("late private text", null)
            assertNull(second.value)
            assertEquals(1, second.replies)
            assertTrue(host.stops >= 2)
        } finally {
            bridge.dispose()
            controller.pause().stop().destroy()
        }
    }

    @Test fun invalidTranscriptAndMalformedPayloadFailClosedWithoutAReceipt() {
        val controller = activity()
        val activity = controller.get()
        Shadows.shadowOf(activity.application).grantPermissions(Manifest.permission.RECORD_AUDIO)
        val messenger = Messenger()
        val host = Host()
        val bridge = LocalSpeechBridge(activity, messenger, host) { true }
        try {
            bridge.setResumed(true)
            val invalid = messenger.call("recognize", mapOf("locale" to "en-US"))
            host.recognition!!("hidden\u2066direction", null)
            assertEquals("invalidTranscript", invalid.error)
            assertNull(invalid.value)
            assertEquals(1, invalid.replies)

            val malformed = messenger.call("speak", mapOf(
                "locale" to "en-US",
                "text" to "hello",
                "unknown" to true,
            ))
            assertEquals("invalidRequest", malformed.error)
            assertTrue(host.speeches.isEmpty())

            val unsupportedLocale = messenger.call("recognize", mapOf("locale" to "en-GB"))
            assertEquals("invalidRequest", unsupportedLocale.error)
            assertEquals(1, host.recognitions.size)
        } finally {
            bridge.dispose()
            controller.pause().stop().destroy()
        }
    }

    @Test fun speechReceiptIsOnlyReturnedAfterExactLocalHostCompletion() {
        val controller = activity()
        val messenger = Messenger()
        val host = Host()
        val bridge = LocalSpeechBridge(controller.get(), messenger, host) { true }
        try {
            bridge.setResumed(true)
            val spoken = messenger.call("speak", mapOf("locale" to "en-US", "text" to "Lights are off"))
            assertEquals(listOf("en-US" to "Lights are off"), host.speeches)
            assertEquals(0, spoken.replies)
            host.speech!!(null)
            assertEquals(mapOf("schemaVersion" to 1, "onDevice" to true, "text" to null), spoken.value)
            assertEquals(1, spoken.replies)
        } finally {
            bridge.dispose()
            controller.pause().stop().destroy()
        }
    }
}
