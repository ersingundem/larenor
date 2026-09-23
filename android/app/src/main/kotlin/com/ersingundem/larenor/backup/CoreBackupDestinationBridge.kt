package com.ersingundem.larenor.backup

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal interface CoreBackupOutput {
    fun write(bytes: ByteArray)
    fun finish()
    fun close()
}

internal interface CoreBackupDestinationHost {
    fun launch(intent: Intent, requestCode: Int)
    fun open(uri: Uri): CoreBackupOutput
    fun delete(uri: Uri)
}

private class AndroidCoreBackupOutput(
    descriptor: ParcelFileDescriptor,
) : CoreBackupOutput {
    private val stream = ParcelFileDescriptor.AutoCloseOutputStream(descriptor)
    override fun write(bytes: ByteArray) = stream.write(bytes)
    override fun finish() {
        stream.flush()
        stream.fd.sync()
        stream.close()
    }
    override fun close() = stream.close()
}

private class AndroidCoreBackupDestinationHost(
    private val activity: Activity,
) : CoreBackupDestinationHost {
    override fun launch(intent: Intent, requestCode: Int) =
        activity.startActivityForResult(intent, requestCode)

    override fun open(uri: Uri): CoreBackupOutput {
        val descriptor = activity.contentResolver.openFileDescriptor(uri, "rwt")
            ?: throw IllegalStateException("destination_unavailable")
        return AndroidCoreBackupOutput(descriptor)
    }

    override fun delete(uri: Uri) {
        try { activity.contentResolver.delete(uri, null, null) } catch (_: Exception) { }
    }
}

class CoreBackupDestinationBridge internal constructor(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val host: CoreBackupDestinationHost = AndroidCoreBackupDestinationHost(activity),
    private val maxBytes: Long = MAX_BYTES,
    private val requestCodePool: CoreBackupRequestCodePool = REQUEST_CODES,
) : MethodChannel.MethodCallHandler {
    private data class Pending(
        val sessionId: String,
        val requestCode: Int,
        val result: MethodChannel.Result,
        @Volatile var cancelled: Boolean = false,
        @Volatile var replied: Boolean = false,
        @Volatile var pickerOutstanding: Boolean = true,
    )

    private data class Active(
        val sessionId: String,
        val handle: String,
        val uri: Uri,
        val output: CoreBackupOutput,
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256"),
        var bytes: Long = 0,
    ) { @Volatile var retired: Boolean = false }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    // Remains able to accept a late picker result after dispose, but owns no
    // thread while idle. This avoids both UI-thread SAF I/O and shutdown races.
    private val io = ThreadPoolExecutor(
        0,
        1,
        1,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(),
    )
    private var pending: Pending? = null
    private val openingLock = Any()
    private var opening: Pair<Uri, CoreBackupOutput>? = null
    @Volatile
    private var active: Active? = null
    @Volatile private var disposed = false

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return fail(result, "expired")
        try {
            when (call.method) {
                "open" -> open(call.arguments, result)
                "append" -> append(call.arguments, result)
                "commit" -> commit(call.arguments, result)
                "cancel" -> cancel(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            fail(result, "invalid_request")
        } catch (_: Exception) {
            retireActive(delete = true)
            fail(result, "unavailable")
        }
    }

    private fun open(raw: Any?, result: MethodChannel.Result) {
        val map = exact(raw, setOf("sessionId", "fileName", "mimeType"))
        val session = id(map["sessionId"])
        if (
            map["fileName"] != "larenor-core-backup.larenor-core" ||
            map["mimeType"] != MIME
        ) throw IllegalArgumentException()
        if (pending != null || active != null) return fail(result, "busy")
        val operation = Pending(session, requestCodePool.allocate(), result)
        pending = operation
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(MIME)
            .putExtra(Intent.EXTRA_TITLE, "larenor-core-backup.larenor-core")
        try { host.launch(intent, operation.requestCode) } catch (error: Exception) {
            pending = null
            check(requestCodePool.complete(operation.requestCode))
            throw error
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCodePool.consumeRetired(requestCode)) {
            data?.data?.let { uri -> io.execute { host.delete(uri) } }
            return true
        }
        val operation = pending?.takeIf { it.requestCode == requestCode } ?: return false
        operation.pickerOutstanding = false
        if (!requestCodePool.complete(requestCode)) {
            operation.replied = true
            fail(operation.result, "unavailable")
            if (pending === operation) pending = null
            return true
        }
        val uri = data?.data
        if (operation.cancelled || resultCode != Activity.RESULT_OK || uri == null) {
            if (uri != null) io.execute { host.delete(uri) }
            if (!operation.replied) operation.result.success(null)
            pending = null
            return true
        }
        if (uri.scheme != "content" || uri.authority.isNullOrBlank()) {
            io.execute { host.delete(uri) }
            if (!operation.replied) fail(operation.result, "unavailable")
            pending = null
            return true
        }
        io.execute {
            val opened = try { host.open(uri) } catch (_: Exception) { null }
            if (opened == null) host.delete(uri)
            else synchronized(openingLock) { opening = uri to opened }
            main.post {
                if (opened == null) {
                    if (!operation.replied) fail(operation.result, "unavailable")
                } else if (
                    disposed || operation.cancelled || pending !== operation
                ) {
                    takeOpening(opened)?.let { stale ->
                        io.execute {
                        try { opened.close() } catch (_: Exception) { }
                            host.delete(stale.first)
                        }
                    }
                    if (!operation.replied) fail(operation.result, "expired")
                } else {
                    takeOpening(opened)
                    val handle = UUID.randomUUID().toString().replace("-", "")
                    active = Active(operation.sessionId, handle, uri, opened)
                    operation.replied = true
                    operation.result.success(mapOf("handle" to handle))
                }
                if (pending === operation) pending = null
            }
        }
        return true
    }

    private fun append(raw: Any?, result: MethodChannel.Result) {
        val map = exact(raw, setOf("sessionId", "handle", "bytes"))
        val current = requireActive(map)
        val bytes = map["bytes"] as? ByteArray ?: throw IllegalArgumentException()
        if (bytes.isEmpty() || bytes.size > MAX_CHUNK) {
            retireActive(delete = true)
            return fail(result, "invalid_request")
        }
        io.execute {
            if (current.retired || active !== current) {
                main.post { fail(result, "expired") }
                return@execute
            }
            try {
                if (current.bytes + bytes.size > maxBytes) throw IllegalArgumentException()
                current.output.write(bytes)
                current.digest.update(bytes)
                current.bytes += bytes.size
                main.post {
                    if (current.retired || active !== current) fail(result, "expired")
                    else result.success(null)
                }
            } catch (_: IllegalArgumentException) {
                main.post {
                    retireActive(delete = true)
                    fail(result, "invalid_request")
                }
            } catch (_: Exception) {
                main.post {
                    retireActive(delete = true)
                    fail(result, "unavailable")
                }
            }
        }
    }

    private fun commit(raw: Any?, result: MethodChannel.Result) {
        val map = exact(raw, setOf("sessionId", "handle", "byteLength", "sha256"))
        val current = requireActive(map)
        val length = (map["byteLength"] as? Number)?.toLong() ?: throw IllegalArgumentException()
        val digest = map["sha256"] as? String ?: throw IllegalArgumentException()
        if (length !in 1..maxBytes || !DIGEST.matches(digest)) {
            retireActive(delete = true)
            return fail(result, "invalid_request")
        }
        io.execute {
            if (current.retired || active !== current) {
                main.post { fail(result, "expired") }
                return@execute
            }
            try {
                val expected = digest.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                if (
                    length != current.bytes ||
                    !MessageDigest.isEqual(current.digest.digest(), expected)
                ) throw IllegalArgumentException()
                current.output.finish()
                main.post {
                    if (current.retired || active !== current) {
                        fail(result, "expired")
                    } else {
                        active = null
                        result.success(current.uri.toString())
                    }
                }
            } catch (_: IllegalArgumentException) {
                main.post {
                    retireActive(delete = true)
                    fail(result, "invalid_request")
                }
            } catch (_: Exception) {
                main.post {
                    retireActive(delete = true)
                    fail(result, "unavailable")
                }
            }
        }
    }

    private fun cancel(raw: Any?, result: MethodChannel.Result) {
        val map = raw as? Map<*, *> ?: throw IllegalArgumentException()
        if (map.keys != setOf("sessionId") && map.keys != setOf("sessionId", "handle")) {
            throw IllegalArgumentException()
        }
        val session = id(map["sessionId"])
        pending?.takeIf { it.sessionId == session }?.let {
            retirePending(it)
        }
        active?.takeIf {
            it.sessionId == session && (map["handle"] == null || map["handle"] == it.handle)
        }?.let { retireActive(delete = true) }
        result.success(null)
    }

    private fun retirePending(operation: Pending) {
        operation.cancelled = true
        if (operation.pickerOutstanding) {
            check(requestCodePool.retire(operation.requestCode))
        }
        if (pending === operation) pending = null
        if (!operation.replied) {
            operation.replied = true
            fail(operation.result, "expired")
        }
    }

    private fun requireActive(map: Map<*, *>): Active {
        val current = active ?: throw IllegalArgumentException()
        if (id(map["sessionId"]) != current.sessionId || map["handle"] != current.handle) {
            throw IllegalArgumentException()
        }
        return current
    }

    private fun exact(raw: Any?, keys: Set<String>): Map<*, *> {
        val map = raw as? Map<*, *> ?: throw IllegalArgumentException()
        if (map.keys != keys) throw IllegalArgumentException()
        return map
    }

    private fun id(raw: Any?): String {
        val value = raw as? String ?: throw IllegalArgumentException()
        if (!ID.matches(value)) throw IllegalArgumentException()
        return value
    }

    private fun retireActive(delete: Boolean) {
        val current = active ?: return
        active = null
        current.retired = true
        io.execute {
            try { current.output.close() } catch (_: Exception) { }
            if (delete) host.delete(current.uri)
        }
    }

    private fun takeOpening(output: CoreBackupOutput): Pair<Uri, CoreBackupOutput>? =
        synchronized(openingLock) {
            opening?.takeIf { it.second === output }?.also { opening = null }
        }

    private fun takeOpening(): Pair<Uri, CoreBackupOutput>? =
        synchronized(openingLock) { opening.also { opening = null } }

    fun dispose() {
        if (disposed) return
        disposed = true
        pending?.let(::retirePending)
        retireActive(delete = true)
        io.execute {
            takeOpening()?.let { (uri, output) ->
                try { output.close() } catch (_: Exception) { }
                host.delete(uri)
            }
        }
        channel.setMethodCallHandler(null)
    }

    private fun fail(result: MethodChannel.Result, code: String) =
        result.error(code, "Core backup destination unavailable", null)

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/core_backup_destination"
        private const val FIRST_REQUEST_CODE = 0x4C42
        private const val LAST_REQUEST_CODE = 1
        const val MAX_CHUNK = 64 * 1024
        const val MAX_BYTES = 424L * 1024 * 1024
        const val MIME = "application/vnd.larenor.core-backup"
        private val ID = Regex("^[0-9a-f]{32}$")
        private val DIGEST = Regex("^[0-9a-f]{64}$")
        private val REQUEST_CODES =
            CoreBackupRequestCodePool(FIRST_REQUEST_CODE, LAST_REQUEST_CODE)
    }
}
