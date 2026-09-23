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
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class CoreBackupDestinationBridgeTest {
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
            assertEquals("Core backup destination unavailable", message)
            assertNull(details)
            done = true
        }
        override fun notImplemented() { code = "missing"; done = true }
    }

    private class Output : CoreBackupOutput {
        val bytes = ByteArrayOutputStream()
        @Volatile var finished = false
        @Volatile var closed = false
        @Volatile var writeThread = -1L
        @Volatile var finishThread = -1L
        var writeStarted: CountDownLatch? = null
        var writeGate: CountDownLatch? = null
        override fun write(bytes: ByteArray) {
            writeThread = Thread.currentThread().id
            writeStarted?.countDown()
            writeGate?.await(2, TimeUnit.SECONDS)
            this.bytes.write(bytes)
        }
        override fun finish() {
            finishThread = Thread.currentThread().id
            finished = true
        }
        override fun close() { closed = true }
    }

    private class Host : CoreBackupDestinationHost {
        val output = Output()
        val deleted = Collections.synchronizedList(mutableListOf<Uri>())
        @Volatile var launches = 0
        @Volatile var openCalls = 0
        @Volatile var openThread = -1L
        var openStarted: CountDownLatch? = null
        var openGate: CountDownLatch? = null
        override fun launch(intent: Intent, requestCode: Int) {
            assertEquals(Intent.ACTION_CREATE_DOCUMENT, intent.action)
            assertEquals(CoreBackupDestinationBridge.REQUEST_CODE, requestCode)
            launches++
        }
        override fun open(uri: Uri): CoreBackupOutput {
            openCalls++
            openThread = Thread.currentThread().id
            openStarted?.countDown()
            openGate?.await(2, TimeUnit.SECONDS)
            return output
        }
        override fun delete(uri: Uri) { deleted += uri }
    }

    private fun args(session: String, handle: String, extra: Map<String, Any>) =
        mapOf("sessionId" to session, "handle" to handle) + extra

    private fun open(bridge: CoreBackupDestinationBridge, session: String, uri: Uri): Result {
        val result = Result()
        bridge.onMethodCall(MethodCall("open", mapOf(
            "sessionId" to session,
            "fileName" to "larenor-core-backup.larenor-core",
            "mimeType" to CoreBackupDestinationBridge.MIME,
        )), result)
        assertTrue(bridge.onActivityResult(
            CoreBackupDestinationBridge.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(uri),
        ))
        await(result)
        return result
    }

    private fun await(result: Result) = awaitCondition { result.done }

    private fun awaitCondition(condition: () -> Boolean) {
        repeat(400) {
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) return
            Thread.sleep(5)
        }
        fail("Timed out waiting for asynchronous bridge work")
    }

    @Test fun streamsBoundedChunksOffMainAndCommitsOnlyExactLengthAndDigest() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = CoreBackupDestinationBridge(activity, Messenger(), host)
        try {
            val session = "a".repeat(32)
            val uri = Uri.parse("content://documents/backup")
            val opened = open(bridge, session, uri)
            val handle = (opened.value as Map<*, *>)["handle"] as String
            val payload = ByteArray(64 * 1024) { (it % 251).toByte() }
            val append = Result()
            bridge.onMethodCall(MethodCall("append", args(
                session, handle, mapOf("bytes" to payload),
            )), append)
            await(append)
            val digest = MessageDigest.getInstance("SHA-256").digest(payload)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val commit = Result()
            bridge.onMethodCall(MethodCall("commit", args(session, handle, mapOf(
                "byteLength" to payload.size.toLong(), "sha256" to digest,
            ))), commit)
            await(commit)

            assertEquals(uri.toString(), commit.value)
            assertArrayEquals(payload, host.output.bytes.toByteArray())
            assertTrue(host.output.finished)
            assertTrue(host.deleted.isEmpty())
            assertNotEquals(Thread.currentThread().id, host.openThread)
            assertNotEquals(Thread.currentThread().id, host.output.writeThread)
            assertNotEquals(Thread.currentThread().id, host.output.finishThread)
        } finally { bridge.dispose() }
    }

    @Test fun exactSessionCancelDeletesPartialAndLatePickerCannotClaimNewSession() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = CoreBackupDestinationBridge(activity, Messenger(), host)
        try {
            val old = Result()
            val oldSession = "a".repeat(32)
            bridge.onMethodCall(MethodCall("open", mapOf(
                "sessionId" to oldSession,
                "fileName" to "larenor-core-backup.larenor-core",
                "mimeType" to CoreBackupDestinationBridge.MIME,
            )), old)
            bridge.onMethodCall(MethodCall("cancel", mapOf("sessionId" to oldSession)), Result())
            assertEquals("expired", old.code)
            val stale = Uri.parse("content://documents/stale")
            bridge.onActivityResult(
                CoreBackupDestinationBridge.REQUEST_CODE,
                Activity.RESULT_OK,
                Intent().setData(stale),
            )
            awaitCondition { host.deleted.contains(stale) }
            assertEquals(0, host.openCalls)

            val freshSession = "b".repeat(32)
            val current = Uri.parse("content://documents/current")
            val fresh = open(bridge, freshSession, current)
            val handle = (fresh.value as Map<*, *>)["handle"] as String
            bridge.onMethodCall(MethodCall("cancel", mapOf("sessionId" to oldSession)), Result())
            val append = Result()
            bridge.onMethodCall(MethodCall("append", args(
                freshSession, handle, mapOf("bytes" to byteArrayOf(1, 2, 3)),
            )), append)
            await(append)
            assertArrayEquals(byteArrayOf(1, 2, 3), host.output.bytes.toByteArray())
            bridge.onMethodCall(MethodCall(
                "cancel", args(freshSession, handle, emptyMap()),
            ), Result())
            awaitCondition { host.output.closed && host.deleted.contains(current) }
            assertEquals(listOf(stale, current), host.deleted)
        } finally { bridge.dispose() }
    }

    @Test fun cancelDuringGatedWriteInvalidatesLateAppendAndCommit() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = CoreBackupDestinationBridge(activity, Messenger(), host)
        try {
            val session = "c".repeat(32)
            val uri = Uri.parse("content://documents/cancelled-write")
            val opened = open(bridge, session, uri)
            val handle = (opened.value as Map<*, *>)["handle"] as String
            host.output.writeStarted = CountDownLatch(1)
            host.output.writeGate = CountDownLatch(1)
            val append = Result()
            bridge.onMethodCall(MethodCall("append", args(
                session, handle, mapOf("bytes" to byteArrayOf(7, 8, 9)),
            )), append)
            assertTrue(host.output.writeStarted!!.await(1, TimeUnit.SECONDS))
            bridge.onMethodCall(MethodCall(
                "cancel", args(session, handle, emptyMap()),
            ), Result())
            host.output.writeGate!!.countDown()
            await(append)
            awaitCondition { host.output.closed && host.deleted.contains(uri) }
            assertEquals("expired", append.code)

            val commit = Result()
            bridge.onMethodCall(MethodCall("commit", args(session, handle, mapOf(
                "byteLength" to 3L,
                "sha256" to "0".repeat(64),
            ))), commit)
            assertEquals("invalid_request", commit.code)
            assertFalse(host.output.finished)
            assertEquals(1, host.deleted.count { it == uri })
        } finally { bridge.dispose() }
    }

    @Test fun disposeDuringGatedOpenAndLatePickerDeleteExactlyOnceWithoutCrash() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = CoreBackupDestinationBridge(activity, Messenger(), host)
        val session = "d".repeat(32)
        val opening = Result()
        bridge.onMethodCall(MethodCall("open", mapOf(
            "sessionId" to session,
            "fileName" to "larenor-core-backup.larenor-core",
            "mimeType" to CoreBackupDestinationBridge.MIME,
        )), opening)
        host.openStarted = CountDownLatch(1)
        host.openGate = CountDownLatch(1)
        val uri = Uri.parse("content://documents/gated-open")
        bridge.onActivityResult(
            CoreBackupDestinationBridge.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(uri),
        )
        assertTrue(host.openStarted!!.await(1, TimeUnit.SECONDS))
        bridge.dispose()
        assertEquals("expired", opening.code)
        host.openGate!!.countDown()
        awaitCondition { host.output.closed && host.deleted.contains(uri) }
        assertEquals(1, host.deleted.count { it == uri })

        val lateHost = Host()
        val lateBridge = CoreBackupDestinationBridge(activity, Messenger(), lateHost)
        val lateResult = Result()
        lateBridge.onMethodCall(MethodCall("open", mapOf(
            "sessionId" to "e".repeat(32),
            "fileName" to "larenor-core-backup.larenor-core",
            "mimeType" to CoreBackupDestinationBridge.MIME,
        )), lateResult)
        lateBridge.dispose()
        val lateUri = Uri.parse("content://documents/late-after-dispose")
        lateBridge.onActivityResult(
            CoreBackupDestinationBridge.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(lateUri),
        )
        awaitCondition { lateHost.deleted.contains(lateUri) }
        assertEquals(0, lateHost.openCalls)
        assertEquals(1, lateHost.deleted.count { it == lateUri })
    }
}
