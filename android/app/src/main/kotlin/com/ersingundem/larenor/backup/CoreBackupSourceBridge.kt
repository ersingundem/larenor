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
import java.security.MessageDigest
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

internal interface CoreBackupInput {
    fun read(buffer: ByteArray): Int
    fun close()
}

internal interface CoreBackupSourceHost {
    fun launch(intent: Intent, requestCode: Int)
    fun open(uri: Uri): CoreBackupInput
}

private class AndroidCoreBackupInput(
    descriptor: ParcelFileDescriptor,
) : CoreBackupInput {
    private val stream = ParcelFileDescriptor.AutoCloseInputStream(descriptor)
    override fun read(buffer: ByteArray): Int = stream.read(buffer)
    override fun close() = stream.close()
}

private class AndroidCoreBackupSourceHost(
    private val activity: Activity,
) : CoreBackupSourceHost {
    override fun launch(intent: Intent, requestCode: Int) =
        activity.startActivityForResult(intent, requestCode)

    override fun open(uri: Uri): CoreBackupInput {
        val descriptor = activity.contentResolver.openFileDescriptor(uri, "r")
            ?: throw IllegalStateException("source_unavailable")
        return AndroidCoreBackupInput(descriptor)
    }
}

class CoreBackupSourceBridge internal constructor(
    activity: Activity,
    messenger: BinaryMessenger,
    private val host: CoreBackupSourceHost = AndroidCoreBackupSourceHost(activity),
    private val maxBytes: Long = MAX_BYTES,
    internal val requestCode: Int = allocateRequestCode(),
) : MethodChannel.MethodCallHandler {
    private data class SourceLease(
        val input: CoreBackupInput,
        val closed: AtomicBoolean = AtomicBoolean(false),
    ) {
        fun close() {
            if (closed.compareAndSet(false, true)) {
                try { input.close() } catch (_: Exception) { }
            }
        }
    }

    private data class Pending(
        val sessionId: String,
        val result: MethodChannel.Result,
        @Volatile var cancelled: Boolean = false,
        @Volatile var replied: Boolean = false,
        @Volatile var lease: SourceLease? = null,
    )

    private data class Proof(val byteLength: Long, val sha256: String)
    private class InvalidBackup : Exception()

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val io = ThreadPoolExecutor(
        0,
        1,
        1,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(),
    )
    // Closing a provider descriptor must not run on the UI thread and must be
    // able to retire a read that is currently blocked on the serial scanner.
    private val cleanup = ThreadPoolExecutor(
        0,
        1,
        1,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(),
    )
    private var pending: Pending? = null
    @Volatile private var disposed = false

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return fail(result, "expired")
        try {
            when (call.method) {
                "inspect" -> inspect(call.arguments, result)
                "cancel" -> cancel(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            fail(result, "invalid_request")
        } catch (_: Exception) {
            fail(result, "unavailable")
        }
    }

    private fun inspect(raw: Any?, result: MethodChannel.Result) {
        val map = exact(raw, setOf("sessionId", "mimeType"))
        val session = id(map["sessionId"])
        if (map["mimeType"] != MIME) throw IllegalArgumentException()
        if (pending != null) return fail(result, "busy")
        val operation = Pending(session, result)
        pending = operation
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(MIME)
        try { host.launch(intent, requestCode) } catch (error: Exception) {
            pending = null
            throw error
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != this.requestCode) return false
        val operation = pending ?: return true
        val uri = data?.data
        if (operation.cancelled || resultCode != Activity.RESULT_OK || uri == null) {
            if (!operation.replied) {
                operation.replied = true
                operation.result.success(null)
            }
            if (pending === operation) pending = null
            return true
        }
        if (uri.scheme != "content" || uri.authority.isNullOrBlank()) {
            operation.replied = true
            fail(operation.result, "unavailable")
            if (pending === operation) pending = null
            return true
        }
        io.execute { scan(operation, uri) }
        return true
    }

    private fun scan(operation: Pending, uri: Uri) {
        var proof: Proof? = null
        var error: String? = null
        try {
            if (operation.cancelled || disposed) throw InterruptedException()
            val lease = SourceLease(host.open(uri))
            operation.lease = lease
            if (operation.cancelled || disposed) throw InterruptedException()
            proof = readProof(operation, lease.input)
        } catch (_: InterruptedException) {
            error = "expired"
        } catch (_: InvalidBackup) {
            error = "invalid_backup"
        } catch (_: Exception) {
            error = "unavailable"
        } finally {
            operation.lease?.close()
            operation.lease = null
        }
        val completedProof = proof
        val completedError = error
        main.post {
            val stale = disposed || operation.cancelled || pending !== operation
            if (!operation.replied) {
                operation.replied = true
                if (stale) fail(operation.result, "expired")
                else if (completedError != null) fail(operation.result, completedError)
                else if (completedProof == null) fail(operation.result, "unavailable")
                else operation.result.success(mapOf(
                    "byteLength" to completedProof.byteLength,
                    "sha256" to completedProof.sha256,
                ))
            }
            if (pending === operation) pending = null
        }
    }

    private fun readProof(operation: Pending, input: CoreBackupInput): Proof {
        val buffer = ByteArray(MAX_CHUNK)
        val prefix = ByteArray(MAGIC.size)
        var prefixBytes = 0
        var total = 0L
        val digest = MessageDigest.getInstance("SHA-256")
        while (true) {
            if (operation.cancelled || disposed) throw InterruptedException()
            val read = input.read(buffer)
            if (operation.cancelled || disposed) throw InterruptedException()
            if (read < 0) break
            if (read == 0 || read > buffer.size) throw InvalidBackup()
            total += read
            if (total > maxBytes) throw InvalidBackup()
            digest.update(buffer, 0, read)
            if (prefixBytes < prefix.size) {
                val copy = minOf(read, prefix.size - prefixBytes)
                buffer.copyInto(prefix, prefixBytes, 0, copy)
                prefixBytes += copy
            }
        }
        if (total < MIN_ENVELOPE_BYTES || !MessageDigest.isEqual(prefix, MAGIC)) {
            throw InvalidBackup()
        }
        return Proof(
            total,
            digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) },
        )
    }

    private fun cancel(raw: Any?, result: MethodChannel.Result) {
        val map = exact(raw, setOf("sessionId"))
        val session = id(map["sessionId"])
        pending?.takeIf { it.sessionId == session }?.let {
            it.cancelled = true
            it.lease?.let { lease -> cleanup.execute { lease.close() } }
            if (!it.replied) {
                it.replied = true
                fail(it.result, "expired")
            }
        }
        result.success(null)
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

    fun dispose() {
        if (disposed) return
        disposed = true
        pending?.let {
            it.cancelled = true
            it.lease?.let { lease -> cleanup.execute { lease.close() } }
            if (!it.replied) {
                it.replied = true
                fail(it.result, "expired")
            }
        }
        channel.setMethodCallHandler(null)
    }

    private fun fail(result: MethodChannel.Result, code: String) =
        result.error(code, "Core backup source unavailable", null)

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/core_backup_source"
        private const val FIRST_REQUEST_CODE = 0x4C43
        private const val LAST_REQUEST_CODE = 0xFFFE
        const val MIME = "application/vnd.larenor.core-backup"
        const val MAX_CHUNK = 64 * 1024
        const val MAX_BYTES = 424L * 1024 * 1024
        const val MIN_ENVELOPE_BYTES = 65L
        private val MAGIC = "LARENOR-CORE-BACKUP\u0000\u0001".toByteArray()
        private val ID = Regex("^[0-9a-f]{32}$")
        private val requestCodes = AtomicInteger(FIRST_REQUEST_CODE)

        private fun allocateRequestCode(): Int {
            val value = requestCodes.getAndIncrement()
            check(value <= LAST_REQUEST_CODE) { "backup_source_request_codes_exhausted" }
            return value
        }
    }
}
