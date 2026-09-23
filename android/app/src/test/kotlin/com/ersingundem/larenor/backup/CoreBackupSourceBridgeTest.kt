package com.ersingundem.larenor.backup

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class CoreBackupSourceBridgeTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    private class Result : MethodChannel.Result {
        @Volatile var value: Any? = null
        @Volatile var code: String? = null
        @Volatile var done = false
        override fun success(result: Any?) { value = result; done = true }
        override fun error(code: String, message: String?, details: Any?) {
            this.code = code
            assertEquals("Core backup source unavailable", message)
            assertNull(details)
            done = true
        }
        override fun notImplemented() { code = "missing"; done = true }
    }

    private class Input(
        private val payload: ByteArray,
        private val maxRead: Int = Int.MAX_VALUE,
    ) : CoreBackupInput {
        private var offset = 0
        @Volatile var readThread = -1L
        @Volatile var closes = 0
        var readStarted: CountDownLatch? = null
        var readGate: CountDownLatch? = null
        override fun read(buffer: ByteArray): Int {
            readThread = Thread.currentThread().id
            readStarted?.countDown()
            readGate?.await(2, TimeUnit.SECONDS)
            if (offset == payload.size) return -1
            val count = minOf(buffer.size, maxRead, payload.size - offset)
            payload.copyInto(buffer, 0, offset, offset + count)
            offset += count
            return count
        }
        override fun close() { closes++ }
    }

    private class Host(private val input: Input) : CoreBackupSourceHost {
        @Volatile var launches = 0
        @Volatile var opens = 0
        @Volatile var requestCode = -1
        lateinit var intent: Intent
        override fun launch(intent: Intent, requestCode: Int) {
            this.intent = intent
            this.requestCode = requestCode
            launches++
        }
        override fun open(uri: Uri): CoreBackupInput { opens++; return input }
    }

    private fun bundle(extra: Int = 44): ByteArray =
        "LARENOR-CORE-BACKUP\u0000\u0001".toByteArray() + ByteArray(extra) { 7 }

    private fun inspect(
        bridge: CoreBackupSourceBridge,
        session: String = "a".repeat(32),
    ): Result {
        val result = Result()
        bridge.onMethodCall(MethodCall("inspect", mapOf(
            "sessionId" to session,
            "mimeType" to CoreBackupSourceBridge.MIME,
        )), result)
        return result
    }

    private fun deliver(
        bridge: CoreBackupSourceBridge,
        uri: Uri = Uri.parse("content://documents/backup"),
        requestCode: Int = bridge.requestCode,
    ) {
        assertTrue(bridge.onActivityResult(
            requestCode,
            Activity.RESULT_OK,
            Intent().setData(uri),
        ))
    }

    private fun await(result: Result) {
        awaitCondition { result.done }
    }

    private fun awaitCondition(condition: () -> Boolean) {
        repeat(400) {
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) return
            Thread.sleep(5)
        }
        fail("Timed out waiting for source bridge")
    }

    @Test fun opensReadOnlyDocumentAndReturnsOnlyBoundedProofOffMain() {
        val payload = bundle()
        val input = Input(payload, maxRead = 3)
        val host = Host(input)
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = CoreBackupSourceBridge(activity, Messenger(), host)
        try {
            val result = inspect(bridge)
            assertEquals(Intent.ACTION_OPEN_DOCUMENT, host.intent.action)
            assertTrue(host.intent.categories.contains(Intent.CATEGORY_OPENABLE))
            assertEquals(CoreBackupSourceBridge.MIME, host.intent.type)
            deliver(bridge)
            await(result)

            val proof = result.value as Map<*, *>
            val digest = MessageDigest.getInstance("SHA-256").digest(payload)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            assertEquals(payload.size.toLong(), proof["byteLength"])
            assertEquals(digest, proof["sha256"])
            assertEquals(setOf("byteLength", "sha256"), proof.keys)
            assertNotEquals(Thread.currentThread().id, input.readThread)
            assertEquals(1, input.closes)
        } finally { bridge.dispose() }
    }

    @Test fun rejectsWrongEnvelopeAndOverflowWithoutReturningMetadata() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        listOf(
            Input("WRONG".toByteArray() + ByteArray(60)),
            Input(bundle(extra = 50)),
        ).forEachIndexed { index, input ->
            val bridge = CoreBackupSourceBridge(activity, Messenger(), Host(input), maxBytes = 70)
            try {
                val result = inspect(bridge, (index + 1).toString().repeat(32))
                deliver(bridge)
                await(result)
                assertEquals("invalid_backup", result.code)
                assertNull(result.value)
                assertEquals(1, input.closes)
            } finally { bridge.dispose() }
        }
    }

    @Test fun lifecycleCancelRetiresGatedReadAndCannotPublishLateSuccess() {
        val input = Input(bundle()).also {
            it.readStarted = CountDownLatch(1)
            it.readGate = CountDownLatch(1)
        }
        val host = Host(input)
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = CoreBackupSourceBridge(activity, Messenger(), host)
        try {
            val open = inspect(bridge)
            deliver(bridge)
            assertTrue(input.readStarted!!.await(2, TimeUnit.SECONDS))
            val cancel = Result()
            bridge.onMethodCall(MethodCall("cancel", mapOf("sessionId" to "a".repeat(32))), cancel)
            assertTrue(cancel.done)
            awaitCondition { input.closes == 1 }
            input.readGate!!.countDown()
            await(open)

            assertEquals("expired", open.code)
            assertNull(open.value)
            assertEquals(1, input.closes)
        } finally { bridge.dispose() }
    }

    @Test fun cancelledPickerCannotBeReboundToAStaleActivityResult() {
        val input = Input(bundle())
        val host = Host(input)
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = CoreBackupSourceBridge(activity, Messenger(), host)
        try {
            val open = inspect(bridge)
            val requestCode = host.requestCode
            val cancel = Result()
            bridge.onMethodCall(MethodCall("cancel", mapOf("sessionId" to "a".repeat(32))), cancel)
            assertEquals("expired", open.code)
            deliver(bridge, requestCode = requestCode)
            shadowOf(Looper.getMainLooper()).idle()

            assertEquals(0, host.opens)
            assertEquals(0, input.closes)
            assertEquals("expired", open.code)
        } finally { bridge.dispose() }
    }

    @Test fun cancelledPickerImmediatelyReleasesANewSessionWithANewRequestCode() {
        val input = Input(bundle())
        val host = Host(input)
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = CoreBackupSourceBridge(activity, Messenger(), host)
        try {
            val old = inspect(bridge, "a".repeat(32))
            val oldRequestCode = host.requestCode
            bridge.onMethodCall(
                MethodCall("cancel", mapOf("sessionId" to "a".repeat(32))),
                Result(),
            )
            val current = inspect(bridge, "b".repeat(32))

            assertEquals("expired", old.code)
            assertEquals(2, host.launches)
            assertNotEquals(oldRequestCode, host.requestCode)
            assertFalse(current.done)
        } finally { bridge.dispose() }
    }

    @Test fun staleCancelledPickerResultCannotOpenOrCompleteTheCurrentSession() {
        val input = Input(bundle())
        val host = Host(input)
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = CoreBackupSourceBridge(activity, Messenger(), host)
        try {
            val old = inspect(bridge, "a".repeat(32))
            val oldRequestCode = host.requestCode
            bridge.onMethodCall(
                MethodCall("cancel", mapOf("sessionId" to "a".repeat(32))),
                Result(),
            )
            val current = inspect(bridge, "b".repeat(32))
            val currentRequestCode = host.requestCode

            deliver(
                bridge,
                uri = Uri.parse("content://documents/stale-old-picker"),
                requestCode = oldRequestCode,
            )
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("expired", old.code)
            assertEquals(0, host.opens)
            assertFalse(current.done)

            deliver(
                bridge,
                uri = Uri.parse("content://documents/current-picker"),
                requestCode = currentRequestCode,
            )
            await(current)
            assertNotNull(current.value)
            assertEquals(1, host.opens)
        } finally { bridge.dispose() }
    }

    @Test fun disposedBridgeResultCannotBeConsumedByNewBridgePicker() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val oldHost = Host(Input(bundle()))
        val oldBridge = CoreBackupSourceBridge(activity, Messenger(), oldHost)
        val old = inspect(oldBridge, "d".repeat(32))
        val oldRequestCode = oldHost.requestCode
        oldBridge.dispose()
        assertEquals("expired", old.code)

        val currentInput = Input(bundle())
        val currentHost = Host(currentInput)
        val currentBridge = CoreBackupSourceBridge(activity, Messenger(), currentHost)
        try {
            val current = inspect(currentBridge, "e".repeat(32))
            assertNotEquals(oldRequestCode, currentHost.requestCode)
            assertTrue(currentBridge.onActivityResult(
                oldRequestCode,
                Activity.RESULT_OK,
                Intent().setData(Uri.parse("content://documents/stale-old-picker")),
            ))
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(0, currentHost.opens)
            assertFalse(current.done)

            deliver(currentBridge, Uri.parse("content://documents/current-picker"))
            await(current)
            assertNotNull(current.value)
            assertEquals(1, currentHost.opens)
            assertEquals(1, currentInput.closes)
        } finally { currentBridge.dispose() }
    }
}
