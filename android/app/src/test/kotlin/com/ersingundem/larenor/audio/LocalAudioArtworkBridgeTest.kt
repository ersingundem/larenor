package com.ersingundem.larenor.audio

import android.app.Activity
import android.app.Application
import android.graphics.Bitmap
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.plugin.common.FlutterException
import java.nio.ByteBuffer
import java.io.ByteArrayOutputStream
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class LocalAudioArtworkBridgeTest {
    private class Queue : AbstractExecutorService() {
        val queued = mutableListOf<Runnable>()
        var closed = false
        override fun execute(command: Runnable) { queued.add(command) }
        override fun shutdown() { closed = true }
        override fun shutdownNow(): MutableList<Runnable> { closed = true; val old = queued.toMutableList(); queued.clear(); return old }
        override fun isShutdown() = closed
        override fun isTerminated() = closed
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = closed
        fun run() { val work = queued.toList(); queued.clear(); work.forEach { it.run() } }
    }
    private class Result { var value: Any? = null; var error: String? = null; var replies = 0 }
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) { handlers[channel] = handler }
        fun call(name: String, payload: Any?): Result {
            val result = Result()
            val codec = StandardMethodCodec.INSTANCE
            val buffer = codec.encodeMethodCall(MethodCall(name, payload)); buffer.flip()
            handlers[LocalAudioBridge.METHODS]!!.onMessage(buffer) { reply ->
                result.replies++
                reply!!.flip()
                try { result.value = codec.decodeEnvelope(reply) }
                catch (error: FlutterException) { result.error = error.code; assertNull(error.details); assertFalse(error.message.orEmpty().contains("secret")) }
            }
            return result
        }
    }
    private fun image(): ByteArray {
        val bitmap = Bitmap.createBitmap(16, 8, Bitmap.Config.ARGB_8888)
        val bytes = ByteArrayOutputStream(); bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes); bitmap.recycle(); return bytes.toByteArray()
    }
    private fun pump() = Shadows.shadowOf(Looper.getMainLooper()).idle()
    @Test fun actualMethodChannelPreparesBoundedPixelsWithoutStartingServiceAndRejectsDuplicate() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val messenger = Messenger(); val worker = Queue()
        val bridge = LocalAudioBridge(activity.get(), messenger, worker)
        try {
            val background = messenger.call("prepareArtwork", image())
            assertEquals("foregroundRequired", background.error)
            bridge.setResumed(true)
            val invalid = messenger.call("prepareArtwork", "https://example/image?token=secret")
            assertEquals("invalidArtwork", invalid.error)
            val first = messenger.call("prepareArtwork", image())
            val duplicate = messenger.call("prepareArtwork", image())
            assertEquals("busy", duplicate.error)
            assertEquals(1, worker.queued.size)
            worker.run(); pump()
            assertEquals(1, first.replies)
            assertNull(first.error)
            val packet = first.value as Map<*, *>
            assertEquals(setOf("bytes", "width", "height"), packet.keys)
            assertEquals(16, packet["width"])
            assertNull(Shadows.shadowOf(activity.get()).nextStartedService)
            assertFalse(LocalAudioRuntime.coordinator.hasPending)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }
    @Test fun backgroundAndDisposeCompleteOnceAndCannotResurrectLateDecodedPixels() {
        for (dispose in listOf(false, true)) {
            val activity = Robolectric.buildActivity(Activity::class.java).setup()
            val messenger = Messenger(); val worker = Queue()
            val bridge = LocalAudioBridge(activity.get(), messenger, worker)
            try {
                bridge.setResumed(true)
                val first = messenger.call("prepareArtwork", image())
                worker.run()
                if (dispose) bridge.dispose() else bridge.setResumed(false)
                pump()
                assertEquals(1, first.replies)
                assertEquals("unavailable", first.error)
                assertNull(first.value)
                assertNull(Shadows.shadowOf(activity.get()).nextStartedService)
            } finally { if (!dispose) bridge.dispose(); activity.pause().stop().destroy() }
        }
    }
}
