package com.ersingundem.larenor.rdp

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.util.AtomicFile
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

internal enum class RdpSafGrantPhase(val wire: String) {
    SELECT_PENDING("select_pending"),
    ACQUIRE_INTENT("acquire_intent"),
    PREPARED("prepared"),
    ACTIVE("active"),
    RETIRE_INTENT("retire_intent"),
    RELEASE_DISPATCHED("release_dispatched"),
    RETIRED("retired"),
}

internal data class RdpSafGrantRecord(
    val authority: RdpSafAuthority,
    val grantId: String,
    val grantRevision: Long,
    val phase: RdpSafGrantPhase,
    val selectRequestId: String,
    val createdAtMs: Long,
    val expiresAtMs: Long,
    val uri: String?,
    val requiredFlags: Int,
    val preexistingFlags: Int,
    val acquiredFlags: Int,
    val activationRequestId: String?,
    val retirementRequestId: String?,
) {
    val publicState: RdpSafPublicState
        get() = when (phase) {
            RdpSafGrantPhase.PREPARED -> RdpSafPublicState.PREPARED
            RdpSafGrantPhase.ACTIVE -> RdpSafPublicState.ACTIVE
            RdpSafGrantPhase.RETIRED -> RdpSafPublicState.RETIRED
            else -> RdpSafPublicState.UNKNOWN
        }
}

/** Encrypted, bounded local ledger. It never clears or repairs untrusted bytes. */
internal class RdpSafGrantStore(
    context: Context,
    private val testKeyProvider: ((Boolean) -> SecretKey)? = null,
    rootOverride: File? = null,
) {
    companion object {
        const val MAX_PER_AUTHORITY = 32
        const val MAX_GLOBAL = 256
        private const val MAX_FILE_BYTES = 2 * 1024 * 1024
        private const val DIRECTORY = "rdp-saf-grants-v1"
        private const val FILE = "ledger.enc"
        private const val KEY_ALIAS = "larenor_rdp_saf_grants_key_v1"
        private const val AAD = "larenor.rdp-saf-grants.v1"
        private val lock = Any()
    }

    private val root = rootOverride ?: File(context.noBackupFilesDir, DIRECTORY)
    internal val fileForTest = File(root, FILE)
    private val atomic = AtomicFile(fileForTest)

    fun read(): List<RdpSafGrantRecord> = synchronized(lock) {
        if (!fileForTest.exists()) return@synchronized emptyList()
        ensureSafePath(existing = true)
        try {
            decode(decrypt(readBounded()))
        } catch (failure: RdpSafFailure) {
            throw failure
        } catch (_: Exception) {
            unavailable()
        }
    }

    fun replace(records: List<RdpSafGrantRecord>) = synchronized(lock) {
        validate(records)
        ensureSafePath(existing = false)
        val plain = encode(records).toString().toByteArray(StandardCharsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, testKeyProvider?.invoke(true) ?: key(true))
        cipher.updateAAD(AAD.toByteArray(StandardCharsets.UTF_8))
        val encrypted = cipher.doFinal(plain)
        plain.fill(0)
        val envelope = JSONObject()
            .put("schemaVersion", 1)
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .toString().toByteArray(StandardCharsets.UTF_8)
        encrypted.fill(0)
        if (envelope.size > MAX_FILE_BYTES) unavailable()
        var stream: java.io.FileOutputStream? = null
        try {
            stream = atomic.startWrite()
            Os.fchmod(stream.fd, 0b110_000_000)
            stream.write(envelope)
            stream.fd.sync()
            atomic.finishWrite(stream)
            stream = null
            Os.chmod(fileForTest.absolutePath, 0b110_000_000)
        } catch (_: Exception) {
            if (stream != null) atomic.failWrite(stream)
            unavailable()
        } finally {
            envelope.fill(0)
        }
    }

    private fun readBounded(): ByteArray {
        val output = ByteArrayOutputStream()
        atomic.openRead().use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (output.size() + read > MAX_FILE_BYTES) unavailable()
                output.write(buffer, 0, read)
            }
            buffer.fill(0)
        }
        return output.toByteArray()
    }

    private fun decrypt(raw: ByteArray): ByteArray {
        try {
            val envelope = JSONObject(String(raw, StandardCharsets.UTF_8))
            if (envelope.keys().asSequence().toSet() != setOf("schemaVersion", "iv", "ciphertext") ||
                envelope.get("schemaVersion") !is Int || envelope.getInt("schemaVersion") != 1
            ) unavailable()
            val iv = Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)
            val ciphertext = Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)
            if (iv.size != 12 || ciphertext.size < 16 || ciphertext.size > MAX_FILE_BYTES) unavailable()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                testKeyProvider?.invoke(false) ?: key(false),
                GCMParameterSpec(128, iv),
            )
            cipher.updateAAD(AAD.toByteArray(StandardCharsets.UTF_8))
            return cipher.doFinal(ciphertext)
        } finally {
            raw.fill(0)
        }
    }

    private fun encode(records: List<RdpSafGrantRecord>): JSONObject {
        val entries = JSONArray()
        records.forEach { record ->
            entries.put(JSONObject()
                .put("authority", JSONObject()
                    .put("schemaVersion", 5)
                    .put("namespaceDigest", record.authority.namespaceDigest)
                    .put("profileRef", record.authority.profileRef)
                    .put("profileRevision", record.authority.profileRevision))
                .put("authorityId", record.authority.authorityId)
                .put("grantId", record.grantId)
                .put("grantRevision", record.grantRevision)
                .put("phase", record.phase.wire)
                .put("selectRequestId", record.selectRequestId)
                .put("createdAtMs", record.createdAtMs)
                .put("expiresAtMs", record.expiresAtMs)
                .put("uri", record.uri ?: JSONObject.NULL)
                .put("requiredFlags", record.requiredFlags)
                .put("preexistingFlags", record.preexistingFlags)
                .put("acquiredFlags", record.acquiredFlags)
                .put("activationRequestId", record.activationRequestId ?: JSONObject.NULL)
                .put("retirementRequestId", record.retirementRequestId ?: JSONObject.NULL))
        }
        return JSONObject().put("schemaVersion", 1).put("records", entries)
    }

    private fun decode(plain: ByteArray): List<RdpSafGrantRecord> {
        try {
            val root = JSONObject(String(plain, StandardCharsets.UTF_8))
            if (root.keys().asSequence().toSet() != setOf("schemaVersion", "records") ||
                root.get("schemaVersion") !is Int || root.getInt("schemaVersion") != 1
            ) unavailable()
            val values = root.getJSONArray("records")
            if (values.length() > MAX_GLOBAL) unavailable()
            val records = List(values.length()) { index -> decodeRecord(values.getJSONObject(index)) }
            validate(records)
            return records
        } finally {
            plain.fill(0)
        }
    }

    private fun decodeRecord(value: JSONObject): RdpSafGrantRecord {
        if (value.keys().asSequence().toSet() != setOf(
                "authority", "authorityId", "grantId", "grantRevision", "phase",
                "selectRequestId", "createdAtMs", "expiresAtMs", "uri", "requiredFlags",
                "preexistingFlags", "acquiredFlags", "activationRequestId", "retirementRequestId",
            )
        ) unavailable()
        val authority = RdpSafContract.authority(value.getJSONObject("authority").toMap())
        if (value.getString("authorityId") != authority.authorityId) unavailable()
        val phase = RdpSafGrantPhase.entries.singleOrNull { it.wire == value.getString("phase") }
            ?: unavailable()
        return RdpSafGrantRecord(
            authority = authority,
            grantId = value.getString("grantId"),
            grantRevision = value.exactLong("grantRevision"),
            phase = phase,
            selectRequestId = value.getString("selectRequestId"),
            createdAtMs = value.exactLong("createdAtMs"),
            expiresAtMs = value.exactLong("expiresAtMs"),
            uri = value.nullableString("uri"),
            requiredFlags = value.exactInt("requiredFlags"),
            preexistingFlags = value.exactInt("preexistingFlags"),
            acquiredFlags = value.exactInt("acquiredFlags"),
            activationRequestId = value.nullableString("activationRequestId"),
            retirementRequestId = value.nullableString("retirementRequestId"),
        )
    }

    private fun validate(records: List<RdpSafGrantRecord>) {
        if (records.size > MAX_GLOBAL || records.groupingBy { it.grantId }.eachCount().values.any { it != 1 } ||
            records.groupingBy { it.selectRequestId }.eachCount().values.any { it != 1 } ||
            records.groupingBy { it.authority.authorityId }.eachCount().values.any { it > MAX_PER_AUTHORITY }
        ) unavailable()
        val ownedRequests = records.flatMap { listOfNotNull(it.activationRequestId, it.retirementRequestId) }
        if (ownedRequests.size != ownedRequests.toSet().size) unavailable()
        records.forEach { record ->
            if (!RdpSafContract.HEX_32.matches(record.grantId) ||
                !RdpSafContract.UUID.matches(record.selectRequestId) ||
                record.grantRevision !in 1..RdpSafContract.MAX_JS_SAFE_INTEGER ||
                record.createdAtMs <= 0 || record.expiresAtMs <= record.createdAtMs ||
                record.requiredFlags and RdpSafGrantBroker.REQUIRED_FLAGS != RdpSafGrantBroker.REQUIRED_FLAGS ||
                record.preexistingFlags and RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS.inv() != 0 ||
                record.acquiredFlags and RdpSafGrantBroker.REQUIRED_ACCESS_FLAGS.inv() != 0 ||
                record.activationRequestId?.let { !RdpSafContract.UUID.matches(it) } == true ||
                record.retirementRequestId?.let { !RdpSafContract.UUID.matches(it) } == true ||
                record.uri?.let { !it.startsWith("content://") || it.length > 4096 } == true
            ) unavailable()
            if (record.phase in setOf(
                    RdpSafGrantPhase.ACQUIRE_INTENT,
                    RdpSafGrantPhase.PREPARED,
                    RdpSafGrantPhase.ACTIVE,
                    RdpSafGrantPhase.RETIRE_INTENT,
                    RdpSafGrantPhase.RELEASE_DISPATCHED,
                ) && record.uri == null
            ) unavailable()
            if (record.phase == RdpSafGrantPhase.RETIRED && record.uri != null) unavailable()
        }
    }

    private fun ensureSafePath(existing: Boolean) {
        try {
            if (!root.exists() && !root.mkdirs()) unavailable()
            if (!root.isDirectory || Files.isSymbolicLink(root.toPath())) unavailable()
            Os.chmod(root.absolutePath, 0b111_000_000)
            if (fileForTest.exists() && (Files.isSymbolicLink(fileForTest.toPath()) || !fileForTest.isFile)) {
                unavailable()
            }
            if (existing) Os.chmod(fileForTest.absolutePath, 0b110_000_000)
        } catch (failure: RdpSafFailure) {
            throw failure
        } catch (_: Exception) {
            unavailable()
        }
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) unavailable()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { get(it) }

    private fun JSONObject.nullableString(key: String): String? =
        if (isNull(key)) null else get(key) as? String ?: unavailable()

    private fun JSONObject.exactLong(key: String): Long = when (val value = get(key)) {
        is Int -> value.toLong()
        is Long -> value
        else -> unavailable()
    }

    private fun JSONObject.exactInt(key: String): Int = get(key) as? Int ?: unavailable()

    private fun unavailable(): Nothing = throw RdpSafFailure("unavailable")
}
