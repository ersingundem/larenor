package com.ersingundem.larenor.webpanel

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

internal interface WebPanelDownloadHost {
    fun launch(intent: Intent, requestCode: Int)
    fun write(uri: Uri, bytes: ByteArray)
    fun delete(uri: Uri)
}

private class AndroidWebPanelDownloadHost(
    private val activity: Activity,
) : WebPanelDownloadHost {
    override fun launch(intent: Intent, requestCode: Int) =
        activity.startActivityForResult(intent, requestCode)

    override fun write(uri: Uri, bytes: ByteArray) {
        val descriptor = activity.contentResolver.openFileDescriptor(uri, "rwt")
            ?: throw IllegalStateException("destination_unavailable")
        ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { output ->
            output.write(bytes)
            output.flush()
            output.fd.sync()
        }
    }

    override fun delete(uri: Uri) {
        runCatching { activity.contentResolver.delete(uri, null, null) }
    }
}

/**
 * Android-only, one-shot SAF export for already validated WebPanel bytes.
 *
 * The selected content URI never crosses the MethodChannel. All provider I/O
 * runs on one private worker and a retired operation deletes partial output.
 */
class WebPanelDownloadBridge internal constructor(
    activity: Activity,
    messenger: BinaryMessenger,
    private val host: WebPanelDownloadHost = AndroidWebPanelDownloadHost(activity),
    private val maxBytes: Int = MAX_BYTES,
) : MethodChannel.MethodCallHandler {
    private data class Pending(
        val owner: Long,
        val operationId: String,
        val result: MethodChannel.Result,
        val bytes: ByteArray,
        @Volatile var pickerOutstanding: Boolean = true,
        @Volatile var retired: Boolean = false,
        @Volatile var replied: Boolean = false,
    )

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val io = ThreadPoolExecutor(
        0,
        1,
        1,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(),
    ) { runnable -> Thread(runnable, "larenor-webpanel-export").apply { isDaemon = true } }
    @Volatile private var pending: Pending? = null
    @Volatile private var disposed = false

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return fail(result, "expired")
        if (call.method == "cancel") return cancel(call.arguments, result)
        if (call.method != "save") return result.notImplemented()
        try {
            val values = call.arguments as? Map<*, *> ?: throw IllegalArgumentException()
            if (values.keys != setOf("operationId", "fileName", "mimeType", "bytes")) {
                throw IllegalArgumentException()
            }
            val operationId = values["operationId"] as? String
                ?: throw IllegalArgumentException()
            val fileName = values["fileName"] as? String ?: throw IllegalArgumentException()
            val mimeType = values["mimeType"] as? String ?: throw IllegalArgumentException()
            val bytes = values["bytes"] as? ByteArray ?: throw IllegalArgumentException()
            if (
                !ID.matches(operationId) ||
                fileName !in FILE_TYPES ||
                FILE_TYPES[fileName] != mimeType ||
                bytes.isEmpty() ||
                bytes.size > maxBytes ||
                pending != null
            ) throw IllegalArgumentException()
            val owner = acquireOwner() ?: return fail(result, "busy")
            val operation = Pending(owner, operationId, result, bytes.copyOf())
            pending = operation
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType(mimeType)
                .putExtra(Intent.EXTRA_TITLE, fileName)
            try {
                host.launch(intent, REQUEST_CODE)
            } catch (_: Exception) {
                pending = null
                releaseOwner(owner)
                operation.bytes.fill(0)
                fail(result, "unavailable")
            }
        } catch (_: IllegalArgumentException) {
            fail(result, "invalid_request")
        }
    }

    private fun cancel(raw: Any?, result: MethodChannel.Result) {
        val values = raw as? Map<*, *> ?: return fail(result, "invalid_request")
        if (values.keys != setOf("operationId")) return fail(result, "invalid_request")
        val operationId = values["operationId"] as? String
            ?: return fail(result, "invalid_request")
        if (!ID.matches(operationId)) return fail(result, "invalid_request")
        val operation = pending
        if (operation != null && operation.operationId == operationId) {
            operation.retired = true
            operation.bytes.fill(0)
            reply(operation, false)
            if (!operation.pickerOutstanding) pending = null
        }
        result.success(null)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE || !hasOwner()) return false
        val operation = pending
        val uri = data?.data
        if (operation == null || operation.owner != currentOwner()) {
            releaseAnyOwner()
            if (resultCode == Activity.RESULT_OK && validUri(uri)) {
                io.execute { host.delete(uri!!) }
            }
            return true
        }
        operation.pickerOutstanding = false
        releaseOwner(operation.owner)
        if (
            disposed ||
            operation.retired ||
            resultCode != Activity.RESULT_OK ||
            !validUri(uri)
        ) {
            if (resultCode == Activity.RESULT_OK && validUri(uri)) {
                io.execute { host.delete(uri!!) }
            }
            operation.bytes.fill(0)
            reply(operation, false)
            pending = null
            return true
        }
        io.execute {
            var wrote = false
            try {
                if (!operation.retired && pending === operation) {
                    host.write(uri!!, operation.bytes)
                    wrote = true
                }
            } catch (_: Exception) {
                wrote = false
            } finally {
                operation.bytes.fill(0)
            }
            main.post {
                val accepted = wrote && !disposed && !operation.retired && pending === operation
                if (!accepted) io.execute { host.delete(uri!!) }
                reply(operation, accepted)
                if (pending === operation) pending = null
            }
        }
        return true
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        pending?.let { operation ->
            operation.retired = true
            operation.bytes.fill(0)
            reply(operation, false)
            if (!operation.pickerOutstanding) pending = null
        }
    }

    private fun reply(operation: Pending, value: Boolean) {
        if (operation.replied) return
        operation.replied = true
        operation.result.success(value)
    }

    private fun fail(result: MethodChannel.Result, code: String) =
        result.error(code, "WebPanel download unavailable", null)

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/web_panel_download"
        const val MAX_BYTES = 25 * 1024 * 1024
        // Core backup bridges own the complete 1..0xFFFE space in their
        // process-scope pools. Zero is a valid startActivityForResult code and
        // keeps this independent picker from ever consuming a backup result.
        private const val REQUEST_CODE = 0
        private val FILE_TYPES = mapOf(
            "web-panel-download.pdf" to "application/pdf",
            "web-panel-download.jpg" to "image/jpeg",
            "web-panel-download.png" to "image/png",
            "web-panel-download.webp" to "image/webp",
            "web-panel-download.txt" to "text/plain",
            "web-panel-download.csv" to "text/csv",
            "web-panel-download.json" to "application/json",
        )
        private val ID = Regex("^[0-9a-f]{32}$")
        private val ownerSequence = AtomicLong()
        private var outstandingOwner: Long? = null

        private fun acquireOwner(): Long? = synchronized(WebPanelDownloadBridge::class.java) {
            if (outstandingOwner != null) return null
            val owner = ownerSequence.incrementAndGet()
            outstandingOwner = owner
            owner
        }

        private fun hasOwner(): Boolean = synchronized(WebPanelDownloadBridge::class.java) {
            outstandingOwner != null
        }

        private fun currentOwner(): Long? = synchronized(WebPanelDownloadBridge::class.java) {
            outstandingOwner
        }

        private fun releaseOwner(owner: Long) = synchronized(WebPanelDownloadBridge::class.java) {
            if (outstandingOwner == owner) outstandingOwner = null
        }

        private fun releaseAnyOwner() = synchronized(WebPanelDownloadBridge::class.java) {
            outstandingOwner = null
        }

        private fun validUri(uri: Uri?): Boolean =
            uri != null &&
                uri.scheme == "content" &&
                !uri.authority.isNullOrBlank() &&
                uri.userInfo.isNullOrEmpty() &&
                uri.port == -1 &&
                uri.pathSegments.isNotEmpty() &&
                uri.query == null &&
                uri.fragment == null &&
                uri.toString().length <= 2048
    }
}
