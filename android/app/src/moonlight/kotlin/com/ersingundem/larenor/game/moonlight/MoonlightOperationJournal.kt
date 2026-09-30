package com.ersingundem.larenor.game.moonlight

import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files

private const val MAX_OPERATION_EXPIRY_EPOCH_MILLIS = 253_402_300_799_000L

enum class MoonlightOperationState(val wire: String) {
    PREPARED("prepared"),
    DISPATCHING("dispatching"),
    CONFIRMED("confirmed"),
    REJECTED("rejected"),
    UNKNOWN("unknown"),
    REVOKED("revoked");

    val terminal: Boolean
        get() = this in setOf(CONFIRMED, REJECTED, UNKNOWN, REVOKED)
}

data class MoonlightOperationRecord(
    val requestId: String,
    val operationId: String,
    val kind: String,
    val subject: String,
    val fingerprint: String,
    val authorityFingerprint: String,
    val state: MoonlightOperationState,
    val readbackRevision: Long,
    val expiresAtEpochMillis: Long,
    val result: String? = null,
) {
    init {
        requireIdentity(requestId, "request_id")
        requireIdentity(operationId, "candidate")
        require(kind in setOf("pair", "catalog", "revoke", "command", "stream", "stop"))
        requireIdentity(subject, "candidate")
        require(Regex("^[0-9a-f]{64}$").matches(fingerprint))
        require(Regex("^[0-9a-f]{64}$").matches(authorityFingerprint))
        requireRevision(readbackRevision, "revision")
        require(expiresAtEpochMillis == 0L || expiresAtEpochMillis in 1..MAX_OPERATION_EXPIRY_EPOCH_MILLIS)
        require(result == null || result.toByteArray(StandardCharsets.UTF_8).size <= 2048)
    }
}

/** Small durable intent journal. A dispatching/unknown request is never resent. */
class MoonlightOperationJournal(
    private val directory: File,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    init {
        if ((!directory.isDirectory && !directory.mkdirs()) || directory.isSymbolicLink()) {
            throw SecurityException("invalid_journal")
        }
    }

    @Synchronized
    fun reserve(record: MoonlightOperationRecord): MoonlightOperationRecord {
        require(record.state == MoonlightOperationState.PREPARED)
        pruneExpiredTerminalRecords()
        val existing = read(record.requestId)
        if (existing != null) {
            if (existing.fingerprint != record.fingerprint || existing.kind != record.kind ||
                existing.operationId != record.operationId || existing.subject != record.subject ||
                existing.authorityFingerprint != record.authorityFingerprint
            ) throw MoonlightRuntimeFailure("invalid_receipt")
            return existing
        }
        val records = list()
        if (records.any {
                it.kind == record.kind && it.operationId == record.operationId &&
                    it.requestId != record.requestId
            }
        ) throw MoonlightRuntimeFailure("invalid_receipt")
        if (record.expiresAtEpochMillis != 0L && record.expiresAtEpochMillis <= nowMillis()) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
        if (records.any {
                it.kind == record.kind && it.subject == record.subject &&
                    it.state in setOf(MoonlightOperationState.DISPATCHING, MoonlightOperationState.UNKNOWN)
            }
        ) throw MoonlightRuntimeFailure("quarantined")
        if (records.size >= MAX_RECORDS) throw MoonlightRuntimeFailure("busy")
        write(record)
        return record
    }

    @Synchronized
    fun transition(
        requestId: String,
        expected: MoonlightOperationState,
        state: MoonlightOperationState,
        readbackRevision: Long,
        result: String? = null,
    ): MoonlightOperationRecord {
        val current = read(requestId) ?: throw MoonlightRuntimeFailure("invalid_receipt")
        if (current.state != expected) throw MoonlightRuntimeFailure("invalid_receipt")
        val next = current.copy(
            state = state,
            readbackRevision = requireRevision(readbackRevision, "revision"),
            result = result,
        )
        write(next)
        return next
    }

    @Synchronized
    fun read(requestId: String): MoonlightOperationRecord? {
        requireIdentity(requestId, "request_id")
        val file = recordFile(requestId)
        if (!file.exists()) return null
        if (!file.isFile || file.isSymbolicLink() || file.length() !in 1..MAX_RECORD_BYTES) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        return try {
            val bytes = ByteArray(file.length().toInt())
            FileInputStream(file).use { stream ->
                var offset = 0
                while (offset < bytes.size) {
                    val count = stream.read(bytes, offset, bytes.size - offset)
                    if (count < 0) throw MoonlightRuntimeFailure("invalid_receipt")
                    offset += count
                }
                if (stream.read() != -1) throw MoonlightRuntimeFailure("invalid_receipt")
            }
            decode(JSONObject(String(bytes, StandardCharsets.UTF_8)))
        } catch (failure: MoonlightRuntimeFailure) {
            throw failure
        } catch (_: Exception) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
    }

    @Synchronized
    fun list(): List<MoonlightOperationRecord> = directory.listFiles()
        ?.filter { it.name.matches(RECORD_NAME) }
        ?.sortedBy { it.name }
        ?.map { read(it.name.removeSuffix(".json")) ?: throw MoonlightRuntimeFailure("invalid_receipt") }
        ?: emptyList()

    @Synchronized
    fun find(kind: String, operationId: String): MoonlightOperationRecord? {
        require(kind in setOf("pair", "catalog", "revoke", "command", "stream", "stop"))
        requireIdentity(operationId, "candidate")
        return list().singleOrNull { it.kind == kind && it.operationId == operationId }
    }

    /** Advances only after a causal provider callback/readback was observed. */
    @Synchronized
    fun nextReadbackRevision(): Long {
        val file = File(directory, READBACK_COUNTER)
        if (file.exists() && (!file.isFile || file.isSymbolicLink() || file.length() !in 1..32)) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        val current = if (!file.exists()) 0L else try {
            file.readText(StandardCharsets.US_ASCII).toLong().also {
                requireRevision(it, "revision")
                if (it == 0L) throw MoonlightRuntimeFailure("invalid_receipt")
            }
        } catch (failure: MoonlightRuntimeFailure) {
            throw failure
        } catch (_: Exception) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        if (current >= MAX_JS_REVISION) throw MoonlightRuntimeFailure("unknown_effect")
        val next = current + 1
        val atomic = AtomicFile(file)
        val output = try { atomic.startWrite() } catch (_: Exception) {
            throw MoonlightRuntimeFailure("unknown_effect")
        }
        try {
            output.write(next.toString().toByteArray(StandardCharsets.US_ASCII))
            output.fd.sync()
            atomic.finishWrite(output)
        } catch (_: Exception) {
            atomic.failWrite(output)
            throw MoonlightRuntimeFailure("unknown_effect")
        }
        return next
    }

    private fun write(record: MoonlightOperationRecord) {
        val atomic = AtomicFile(recordFile(record.requestId))
        val bytes = encode(record).toString().toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAX_RECORD_BYTES) throw MoonlightRuntimeFailure("invalid_receipt")
        val output = try {
            atomic.startWrite()
        } catch (_: Exception) {
            throw MoonlightRuntimeFailure("unknown_effect")
        }
        try {
            output.write(bytes)
            output.fd.sync()
            atomic.finishWrite(output)
        } catch (_: Exception) {
            atomic.failWrite(output)
            throw MoonlightRuntimeFailure("unknown_effect")
        }
    }

    private fun recordFile(requestId: String): File {
        val file = File(directory, "$requestId.json")
        if (file.canonicalFile.parentFile != directory.canonicalFile) {
            throw MoonlightRuntimeFailure("invalid_request_id")
        }
        return file
    }

    private fun encode(record: MoonlightOperationRecord) = JSONObject()
        .put("schemaVersion", 2)
        .put("requestId", record.requestId)
        .put("operationId", record.operationId)
        .put("kind", record.kind)
        .put("subject", record.subject)
        .put("fingerprint", record.fingerprint)
        .put("authorityFingerprint", record.authorityFingerprint)
        .put("state", record.state.wire)
        .put("readbackRevision", record.readbackRevision)
        .put("expiresAtEpochMillis", record.expiresAtEpochMillis)
        .put("result", record.result ?: JSONObject.NULL)

    private fun decode(value: JSONObject): MoonlightOperationRecord {
        val keys = value.keys().asSequence().toSet()
        val schemaVersion = value.getInt("schemaVersion")
        if ((schemaVersion == 1 && keys != V1_KEYS) || (schemaVersion == 2 && keys != V2_KEYS) ||
            schemaVersion !in setOf(1, 2)
        ) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        val state = MoonlightOperationState.entries.singleOrNull { it.wire == value.getString("state") }
            ?: throw MoonlightRuntimeFailure("invalid_receipt")
        return MoonlightOperationRecord(
            requestId = value.getString("requestId"),
            operationId = value.getString("operationId"),
            kind = value.getString("kind"),
            subject = value.getString("subject"),
            fingerprint = value.getString("fingerprint"),
            authorityFingerprint = value.getString("authorityFingerprint"),
            state = state,
            readbackRevision = value.getLong("readbackRevision"),
            expiresAtEpochMillis = if (schemaVersion == 1) 0L else value.getLong("expiresAtEpochMillis"),
            result = if (value.isNull("result")) null else value.getString("result"),
        )
    }

    /**
     * Deletes only receipts whose upstream authorization has expired and whose outcome is known.
     * Unknown and in-flight records are permanent quarantine evidence. A deleted terminal request
     * cannot be dispatched again because reserve rejects the same expired authorization.
     */
    private fun pruneExpiredTerminalRecords() {
        val cutoff = nowMillis() - TERMINAL_RETENTION_MILLIS
        list().filter { record ->
            record.state.terminal && record.state != MoonlightOperationState.UNKNOWN &&
                record.expiresAtEpochMillis != 0L && record.expiresAtEpochMillis <= cutoff
        }.forEach { record ->
            val file = recordFile(record.requestId)
            if (file.exists() && !file.delete()) throw MoonlightRuntimeFailure("busy")
        }
    }

    private fun File.isSymbolicLink(): Boolean = Files.isSymbolicLink(toPath())

    companion object {
        private const val MAX_RECORDS = 2_048
        private const val MAX_RECORD_BYTES = 4_096L
        private const val TERMINAL_RETENTION_MILLIS = 5 * 60 * 1_000L
        internal const val MAX_RESULT_BYTES = 2_048
        private val RECORD_NAME = Regex("^[0-9a-f]{32}\\.json$")
        private const val READBACK_COUNTER = "readback-counter"
        private val V1_KEYS = setOf(
            "schemaVersion", "requestId", "operationId", "kind", "subject", "fingerprint",
            "authorityFingerprint", "state", "readbackRevision",
            "result",
        )
        private val V2_KEYS = V1_KEYS + "expiresAtEpochMillis"
    }
}
