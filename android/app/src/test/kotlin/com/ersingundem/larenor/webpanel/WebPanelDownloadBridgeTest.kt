package com.ersingundem.larenor.webpanel

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class WebPanelDownloadBridgeTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) = Unit
        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) = Unit
    }

    private class Result : MethodChannel.Result {
        @Volatile var value: Any? = null
        @Volatile var code: String? = null
        @Volatile var done = false
        override fun success(result: Any?) { value = result; done = true }
        override fun error(code: String, message: String?, details: Any?) {
            this.code = code
            assertEquals("WebPanel download unavailable", message)
            assertNull(details)
            done = true
        }
        override fun notImplemented() { code = "missing"; done = true }
    }

    private class Host : WebPanelDownloadHost {
        @Volatile var launches = 0
        @Volatile var requestCode = -1
        @Volatile var writeThread = -1L
        @Volatile var writes = 0
        var writeStarted: CountDownLatch? = null
        var writeGate: CountDownLatch? = null
        val deleted = Collections.synchronizedList(mutableListOf<Uri>())
        var bytes = byteArrayOf()

        override fun launch(intent: Intent, requestCode: Int) {
            assertEquals(Intent.ACTION_CREATE_DOCUMENT, intent.action)
            assertTrue(intent.hasCategory(Intent.CATEGORY_OPENABLE))
            assertEquals("application/pdf", intent.type)
            assertEquals("web-panel-download.pdf", intent.getStringExtra(Intent.EXTRA_TITLE))
            this.requestCode = requestCode
            launches++
        }

        override fun write(uri: Uri, bytes: ByteArray) {
            writeThread = Thread.currentThread().id
            writes++
            writeStarted?.countDown()
            writeGate?.await(2, TimeUnit.SECONDS)
            this.bytes = bytes.copyOf()
        }

        override fun delete(uri: Uri) { deleted += uri }
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
        fail("Timed out waiting for bridge result")
    }

    private fun save(
        bridge: WebPanelDownloadBridge,
        bytes: ByteArray = byteArrayOf(1, 2, 3),
        operationId: String = "0123456789abcdef0123456789abcdef",
    ): Result {
        val result = Result()
        bridge.onMethodCall(
            MethodCall(
                "save",
                mapOf(
                    "operationId" to operationId,
                    "fileName" to "web-panel-download.pdf",
                    "mimeType" to "application/pdf",
                    "bytes" to bytes,
                ),
            ),
            result,
        )
        return result
    }

    @Test
    fun exactContractUsesSafAndReturnsOnlyBooleanReceipt() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = WebPanelDownloadBridge(activity, Messenger(), host)
        try {
            val result = save(bridge)
            assertEquals(1, host.launches)
            assertTrue(
                bridge.onActivityResult(
                    host.requestCode,
                    Activity.RESULT_OK,
                    Intent().setData(Uri.parse("content://documents/export/1")),
                ),
            )
            await(result)
            assertEquals(true, result.value)
            assertNull(result.code)
            assertArrayEquals(byteArrayOf(1, 2, 3), host.bytes)
            assertNotEquals(Looper.getMainLooper().thread.id, host.writeThread)
        } finally {
            bridge.dispose()
        }
    }

    @Test
    fun invalidOrRetiredSafResultCannotWriteOrLeavePartialOutput() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = WebPanelDownloadBridge(activity, Messenger(), host)
        val invalid = save(bridge)
        assertTrue(
            bridge.onActivityResult(
                host.requestCode,
                Activity.RESULT_OK,
                Intent().setData(Uri.parse("file:///private/export.pdf")),
            ),
        )
        await(invalid)
        assertEquals(false, invalid.value)
        assertEquals(0, host.writes)

        host.writeStarted = CountDownLatch(1)
        host.writeGate = CountDownLatch(1)
        val pending = save(bridge)
        val uri = Uri.parse("content://documents/export/2")
        assertTrue(bridge.onActivityResult(host.requestCode, Activity.RESULT_OK, Intent().setData(uri)))
        assertTrue(host.writeStarted!!.await(2, TimeUnit.SECONDS))
        bridge.dispose()
        host.writeGate!!.countDown()
        await(pending)
        assertEquals(false, pending.value)
        awaitCondition { host.deleted == listOf(uri) }
        assertEquals(listOf(uri), host.deleted)
    }

    @Test
    fun malformedRequestsFailBeforePickerAndDisposeConsumesLateResult() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = WebPanelDownloadBridge(activity, Messenger(), host)
        val bad = Result()
        bridge.onMethodCall(
            MethodCall(
                "save",
                mapOf(
                    "operationId" to "0123456789abcdef0123456789abcdef",
                    "fileName" to "private.pdf",
                    "mimeType" to "application/pdf",
                    "bytes" to byteArrayOf(1),
                ),
            ),
            bad,
        )
        assertEquals("invalid_request", bad.code)
        assertEquals(0, host.launches)

        val pending = save(bridge)
        val code = host.requestCode
        bridge.dispose()
        await(pending)
        assertEquals(false, pending.value)
        val stale = Uri.parse("content://documents/export/stale")
        assertTrue(bridge.onActivityResult(code, Activity.RESULT_OK, Intent().setData(stale)))
        awaitCondition { host.deleted == listOf(stale) }
        assertEquals(listOf(stale), host.deleted)
    }

    @Test
    fun cancelledPickerCannotDeleteReturnedContentUri() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = WebPanelDownloadBridge(activity, Messenger(), host)
        try {
            val pending = save(bridge)
            val unowned = Uri.parse("content://documents/existing/user-file")
            assertTrue(
                bridge.onActivityResult(
                    host.requestCode,
                    Activity.RESULT_CANCELED,
                    Intent().setData(unowned),
                ),
            )
            await(pending)
            assertEquals(false, pending.value)
            Thread.sleep(25)
            assertTrue(host.deleted.isEmpty())
            assertEquals(0, host.writes)
        } finally {
            bridge.dispose()
        }
    }

    @Test
    fun cancelIsScopedToExactOperationAndDeletesItsLateCreatedTarget() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = Host()
        val bridge = WebPanelDownloadBridge(activity, Messenger(), host)
        val operationId = "0123456789abcdef0123456789abcdef"
        val pending = save(bridge, operationId = operationId)

        val staleCancel = Result()
        bridge.onMethodCall(
            MethodCall(
                "cancel",
                mapOf("operationId" to "abcdef0123456789abcdef0123456789"),
            ),
            staleCancel,
        )
        assertTrue(staleCancel.done)
        assertFalse(pending.done)

        val cancel = Result()
        bridge.onMethodCall(MethodCall("cancel", mapOf("operationId" to operationId)), cancel)
        assertTrue(cancel.done)
        await(pending)
        assertEquals(false, pending.value)

        val partial = Uri.parse("content://documents/export/retired")
        assertTrue(
            bridge.onActivityResult(
                host.requestCode,
                Activity.RESULT_OK,
                Intent().setData(partial),
            ),
        )
        awaitCondition { host.deleted == listOf(partial) }
        assertEquals(0, host.writes)
        bridge.dispose()
    }
}
