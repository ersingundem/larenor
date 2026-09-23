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
        @Volatile var requestCode = -1
        @Volatile var openCalls = 0
        @Volatile var openThread = -1L
        var openStarted: CountDownLatch? = null
        var openGate: CountDownLatch? = null
        override fun launch(intent: Intent, requestCode: Int) {
            assertEquals(Intent.ACTION_CREATE_DOCUMENT, intent.action)
            this.requestCode = requestCode
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

    private fun open(
        bridge: CoreBackupDestinationBridge,
        host: Host,
        session: String,
        uri: Uri,
    ): Result {
        val result = Result()
        bridge.onMethodCall(MethodCall("open", mapOf(
            "sessionId" to session,
            "fileName" to "larenor-core-backup.larenor-core",
            "mimeType" to CoreBackupDestinationBridge.MIME,
        )), result)
        assertTrue(bridge.onActivityResult(
            host.requestCode,
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
            val opened = open(bridge, host, session, uri)
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

    @Test fun exactConfiguredCapCommitsAndStreamedOverflowDeletesPartial() {
        assertEquals(424L * 1024 * 1024, CoreBackupDestinationBridge.MAX_BYTES)
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val exactHost = Host()
        val exact = CoreBackupDestinationBridge(activity, Messenger(), exactHost, maxBytes = 3)
        try {
            val session = "f".repeat(32)
            val uri = Uri.parse("content://documents/exact-cap")
            val opened = open(exact, exactHost, session, uri)
            val handle = (opened.value as Map<*, *>)["handle"] as String
            val payload = byteArrayOf(1, 2, 3)
            val append = Result()
            exact.onMethodCall(MethodCall("append", args(
                session, handle, mapOf("bytes" to payload),
            )), append)
            await(append)
            val digest = MessageDigest.getInstance("SHA-256").digest(payload)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val commit = Result()
            exact.onMethodCall(MethodCall("commit", args(session, handle, mapOf(
                "byteLength" to 3L, "sha256" to digest,
            ))), commit)
            await(commit)
            assertEquals(uri.toString(), commit.value)
            assertTrue(exactHost.output.finished)
            assertTrue(exactHost.deleted.isEmpty())
        } finally { exact.dispose() }

        val overflowHost = Host()
        val overflow = CoreBackupDestinationBridge(
            activity, Messenger(), overflowHost, maxBytes = 3,
        )
        try {
            val session = "1".repeat(32)
            val uri = Uri.parse("content://documents/overflow")
            val opened = open(overflow, overflowHost, session, uri)
            val handle = (opened.value as Map<*, *>)["handle"] as String
            val append = Result()
            overflow.onMethodCall(MethodCall("append", args(
                session, handle, mapOf("bytes" to byteArrayOf(1, 2, 3, 4)),
            )), append)
            await(append)
            awaitCondition { overflowHost.output.closed && overflowHost.deleted.contains(uri) }
            assertEquals("invalid_request", append.code)
            assertFalse(overflowHost.output.finished)
            assertEquals(1, overflowHost.deleted.count { it == uri })
        } finally { overflow.dispose() }
    }

    @Test fun declaredOverflowDeletesPartialBeforeCommit() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = CoreBackupDestinationBridge(activity, Messenger(), host, maxBytes = 3)
        try {
            val session = "2".repeat(32)
            val uri = Uri.parse("content://documents/declared-overflow")
            val opened = open(bridge, host, session, uri)
            val handle = (opened.value as Map<*, *>)["handle"] as String
            val commit = Result()
            bridge.onMethodCall(MethodCall("commit", args(session, handle, mapOf(
                "byteLength" to 4L, "sha256" to "0".repeat(64),
            ))), commit)
            awaitCondition { host.output.closed && host.deleted.contains(uri) }
            assertEquals("invalid_request", commit.code)
            assertNull(commit.value)
            assertFalse(host.output.finished)
            assertEquals(1, host.deleted.count { it == uri })
        } finally { bridge.dispose() }
    }

    @Test fun cancelledPickerImmediatelyReleasesANewSessionWithANewRequestCode() {
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
            val oldRequestCode = host.requestCode
            bridge.onMethodCall(MethodCall("cancel", mapOf("sessionId" to oldSession)), Result())
            assertEquals("expired", old.code)

            val freshSession = "b".repeat(32)
            val fresh = Result()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "sessionId" to freshSession,
                "fileName" to "larenor-core-backup.larenor-core",
                "mimeType" to CoreBackupDestinationBridge.MIME,
            )), fresh)

            assertEquals(2, host.launches)
            assertNotEquals(oldRequestCode, host.requestCode)
            assertFalse(fresh.done)
        } finally { bridge.dispose() }
    }

    @Test fun staleCancelledPickerResultCannotOpenOrCompleteTheCurrentSession() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = CoreBackupDestinationBridge(activity, Messenger(), host)
        try {
            val oldSession = "3".repeat(32)
            val old = Result()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "sessionId" to oldSession,
                "fileName" to "larenor-core-backup.larenor-core",
                "mimeType" to CoreBackupDestinationBridge.MIME,
            )), old)
            val oldRequestCode = host.requestCode
            bridge.onMethodCall(MethodCall("cancel", mapOf("sessionId" to oldSession)), Result())

            val currentSession = "4".repeat(32)
            val current = Result()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "sessionId" to currentSession,
                "fileName" to "larenor-core-backup.larenor-core",
                "mimeType" to CoreBackupDestinationBridge.MIME,
            )), current)
            val currentRequestCode = host.requestCode
            val staleUri = Uri.parse("content://documents/stale-cancelled")
            assertTrue(bridge.onActivityResult(
                oldRequestCode,
                Activity.RESULT_OK,
                Intent().setData(staleUri),
            ))

            awaitCondition { host.deleted.contains(staleUri) }
            assertEquals(0, host.openCalls)
            assertFalse(current.done)

            val currentUri = Uri.parse("content://documents/current")
            assertTrue(bridge.onActivityResult(
                currentRequestCode,
                Activity.RESULT_OK,
                Intent().setData(currentUri),
            ))
            await(current)
            assertNotNull(current.value)
            assertEquals(1, host.openCalls)
        } finally { bridge.dispose() }
    }

    @Test fun disposedBridgeResultCannotBeConsumedByNewBridgePicker() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val oldHost = Host()
        val oldBridge = CoreBackupDestinationBridge(activity, Messenger(), oldHost)
        val old = Result()
        oldBridge.onMethodCall(MethodCall("open", mapOf(
            "sessionId" to "5".repeat(32),
            "fileName" to "larenor-core-backup.larenor-core",
            "mimeType" to CoreBackupDestinationBridge.MIME,
        )), old)
        val oldRequestCode = oldHost.requestCode
        oldBridge.dispose()
        assertEquals("expired", old.code)

        val currentHost = Host()
        val currentBridge = CoreBackupDestinationBridge(activity, Messenger(), currentHost)
        try {
            val current = Result()
            currentBridge.onMethodCall(MethodCall("open", mapOf(
                "sessionId" to "6".repeat(32),
                "fileName" to "larenor-core-backup.larenor-core",
                "mimeType" to CoreBackupDestinationBridge.MIME,
            )), current)
            val currentRequestCode = currentHost.requestCode
            assertNotEquals(oldRequestCode, currentRequestCode)

            val staleUri = Uri.parse("content://documents/disposed-stale")
            assertTrue(currentBridge.onActivityResult(
                oldRequestCode,
                Activity.RESULT_OK,
                Intent().setData(staleUri),
            ))
            awaitCondition { currentHost.deleted.contains(staleUri) }
            assertEquals(0, currentHost.openCalls)
            assertFalse(current.done)

            val currentUri = Uri.parse("content://documents/replacement-current")
            assertTrue(currentBridge.onActivityResult(
                currentRequestCode,
                Activity.RESULT_OK,
                Intent().setData(currentUri),
            ))
            await(current)
            assertNotNull(current.value)
            assertEquals(1, currentHost.openCalls)
        } finally { currentBridge.dispose() }
    }

    @Test fun cancelDuringGatedWriteInvalidatesLateAppendAndCommit() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = CoreBackupDestinationBridge(activity, Messenger(), host)
        try {
            val session = "c".repeat(32)
            val uri = Uri.parse("content://documents/cancelled-write")
            val opened = open(bridge, host, session, uri)
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
            host.requestCode,
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
            lateHost.requestCode,
            Activity.RESULT_OK,
            Intent().setData(lateUri),
        )
        awaitCondition { lateHost.deleted.contains(lateUri) }
        assertEquals(0, lateHost.openCalls)
        assertEquals(1, lateHost.deleted.count { it == lateUri })
    }
}
