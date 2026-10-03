package com.ersingundem.larenor.rdp

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.security.KeyStore
import java.text.Normalizer
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

internal enum class RdpSafTransferPhase {
    PREPARING,
    SESSION_ACTIVE,
    CLOSE_REQUESTED,
    SEALED,
    DISCARD_INTENT,
    UNKNOWN,
    COMPLETE,
    DISCARDED,
}

internal enum class RdpSafFileCommitPhase {
    SEALED_PRIVATE,
    SAF_COMMIT_INTENT,
    SAF_CREATE_DISPATCHED,
    SAF_CREATED,
    SAF_WRITE_DISPATCHED,
    SAF_VERIFIED,
    UNKNOWN,
}

internal data class RdpSafTransferIdentity(
    val transferId: String,
    val authorityId: String,
    val grantId: String,
    val grantRevision: Long,
    val sessionRequestId: String,
    val sessionRevision: Long,
    val processEpoch: String,
) {
    init {
        require(transferId.matches(Regex("[0-9a-f]{32}")))
        require(authorityId.matches(Regex("[0-9a-f]{64}")))
        require(grantId.matches(Regex("[0-9a-f]{32}")))
        require(grantRevision in 1..MAX_JS_SAFE)
        require(sessionRequestId.matches(UUID_PATTERN))
        require(sessionRevision in 1..MAX_JS_SAFE)
        require(processEpoch.matches(Regex("[0-9a-f]{32}")))
    }

    companion object {
        private const val MAX_JS_SAFE = 9_007_199_254_740_991L
        private val UUID_PATTERN = Regex(
            "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        )
    }
}

internal data class RdpSafTransferFileRecord(
    val name: String,
    val size: Long,
    val sha256: String,
    val privatePath: String,
    val phase: RdpSafFileCommitPhase,
    val providerUri: String? = null,
) {
    init {
        require(name.toByteArray(Charsets.UTF_8).size in 1..255)
        require(size in 0..RdpSafDocumentsAdapter.MAX_FILE_BYTES)
        require(sha256.matches(Regex("[0-9a-f]{64}")))
        require(privatePath.isNotBlank())
        if (phase in setOf(
                RdpSafFileCommitPhase.SAF_CREATED,
                RdpSafFileCommitPhase.SAF_WRITE_DISPATCHED,
                RdpSafFileCommitPhase.SAF_VERIFIED,
            )
        ) require(!providerUri.isNullOrBlank())
    }
}

internal data class RdpSafTransferRecord(
    val identity: RdpSafTransferIdentity,
    val mirrorRoot: String,
    val phase: RdpSafTransferPhase,
    val toRemote: List<RdpSafTransferFileRecord> = emptyList(),
    val fromRemote: List<RdpSafTransferFileRecord> = emptyList(),
    val closeReceiptId: String? = null,
) {
    init {
        require(mirrorRoot.isNotBlank())
        require(toRemote.size + fromRemote.size <= RdpSafDocumentsAdapter.MAX_FILES)
        requireUnique(toRemote)
        requireUnique(fromRemote)
        require(
            Math.addExact(toRemote.sumOf { it.size }, fromRemote.sumOf { it.size }) <=
                RdpSafDocumentsAdapter.MAX_TOTAL_BYTES,
        )
        if (phase in setOf(RdpSafTransferPhase.SEALED, RdpSafTransferPhase.COMPLETE)) {
            require(!closeReceiptId.isNullOrBlank())
        }
        if (phase == RdpSafTransferPhase.COMPLETE) {
            require(fromRemote.all { it.phase == RdpSafFileCommitPhase.SAF_VERIFIED })
        }
    }

    private fun requireUnique(files: List<RdpSafTransferFileRecord>) {
        require(files.map { Normalizer.normalize(it.name, Normalizer.Form.NFC) }.toSet().size == files.size)
    }
}

/**
 * The production store is an authenticated encrypted AtomicFile. replace() is atomic and throws
 * before the in-memory state changes when durable publication is not confirmed.
 */
internal interface RdpSafTransferStore {
    fun read(): RdpSafTransferRecord?
    fun replace(value: RdpSafTransferRecord)
    fun clear(expectedTransferId: String)
}

/** Authenticated encrypted single-transfer ledger. Untrusted bytes are never repaired or cleared. */
internal class RdpSafEncryptedTransferStore(
    context: Context,
    private val testKeyProvider: ((Boolean) -> SecretKey)? = null,
    rootOverride: File? = null,
    private val permissions: RdpSafPrivatePermissions = RdpSafPrivatePermissions.ANDROID,
) : RdpSafTransferStore {
    private val root = rootOverride ?: File(context.noBackupFilesDir, DIRECTORY)
    private val file = File(root, FILE)
    private val atomic = AtomicFile(file)

    @Synchronized
    override fun read(): RdpSafTransferRecord? {
        if (!file.exists()) return null
        ensureSafePath(existing = true)
        return try {
            decode(decrypt(readBounded()))
        } catch (_: Exception) {
            unavailable()
        }
    }

    @Synchronized
    override fun replace(value: RdpSafTransferRecord) {
        ensureSafePath(existing = false)
        val plain = encode(value).toString().toByteArray(StandardCharsets.UTF_8)
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
        if (envelope.size > MAX_LEDGER_BYTES) unavailable()
        var stream: java.io.FileOutputStream? = null
        try {
            stream = atomic.startWrite()
            permissions.descriptor.setMode(stream.fd, RDP_SAF_PRIVATE_FILE_MODE)
            stream.write(envelope)
            stream.fd.sync()
            atomic.finishWrite(stream)
            stream = null
            permissions.path.setMode(file.absolutePath, RDP_SAF_PRIVATE_FILE_MODE)
        } catch (_: Exception) {
            stream?.let(atomic::failWrite)
            unavailable()
        } finally {
            envelope.fill(0)
        }
    }

    @Synchronized
    override fun clear(expectedTransferId: String) {
        val current = read() ?: unavailable()
        if (current.identity.transferId != expectedTransferId ||
            current.phase !in setOf(RdpSafTransferPhase.COMPLETE, RdpSafTransferPhase.DISCARDED)
        ) unavailable()
        ensureSafePath(existing = true)
        if (!file.delete()) unavailable()
    }

    private fun encode(record: RdpSafTransferRecord): JSONObject = JSONObject()
        .put("schemaVersion", 1)
        .put("identity", JSONObject()
            .put("transferId", record.identity.transferId)
            .put("authorityId", record.identity.authorityId)
            .put("grantId", record.identity.grantId)
            .put("grantRevision", record.identity.grantRevision)
            .put("sessionRequestId", record.identity.sessionRequestId)
            .put("sessionRevision", record.identity.sessionRevision)
            .put("processEpoch", record.identity.processEpoch))
        .put("mirrorRoot", record.mirrorRoot)
        .put("phase", record.phase.name)
        .put("toRemote", encodeFiles(record.toRemote))
        .put("fromRemote", encodeFiles(record.fromRemote))
        .put("closeReceiptId", record.closeReceiptId ?: JSONObject.NULL)

    private fun encodeFiles(files: List<RdpSafTransferFileRecord>) = JSONArray().also { array ->
        files.forEach { file ->
            array.put(JSONObject()
                .put("name", file.name)
                .put("size", file.size)
                .put("sha256", file.sha256)
                .put("privatePath", file.privatePath)
                .put("phase", file.phase.name)
                .put("providerUri", file.providerUri ?: JSONObject.NULL))
        }
    }

    private fun decode(plain: ByteArray): RdpSafTransferRecord {
        try {
            val root = JSONObject(String(plain, StandardCharsets.UTF_8))
            requireKeys(root, setOf(
                "schemaVersion", "identity", "mirrorRoot", "phase", "toRemote", "fromRemote",
                "closeReceiptId",
            ))
            if (root.exactInt("schemaVersion") != 1) unavailable()
            val identityJson = root.getJSONObject("identity")
            requireKeys(identityJson, setOf(
                "transferId", "authorityId", "grantId", "grantRevision", "sessionRequestId",
                "sessionRevision", "processEpoch",
            ))
            val identity = RdpSafTransferIdentity(
                identityJson.getString("transferId"),
                identityJson.getString("authorityId"),
                identityJson.getString("grantId"),
                identityJson.exactLong("grantRevision"),
                identityJson.getString("sessionRequestId"),
                identityJson.exactLong("sessionRevision"),
                identityJson.getString("processEpoch"),
            )
            return RdpSafTransferRecord(
                identity = identity,
                mirrorRoot = root.getString("mirrorRoot"),
                phase = enumValue<RdpSafTransferPhase>(root.getString("phase")),
                toRemote = decodeFiles(root.getJSONArray("toRemote")),
                fromRemote = decodeFiles(root.getJSONArray("fromRemote")),
                closeReceiptId = root.nullableString("closeReceiptId"),
            )
        } finally {
            plain.fill(0)
        }
    }

    private fun decodeFiles(values: JSONArray): List<RdpSafTransferFileRecord> {
        if (values.length() > RdpSafDocumentsAdapter.MAX_FILES) unavailable()
        return List(values.length()) { index ->
            val value = values.getJSONObject(index)
            requireKeys(value, setOf("name", "size", "sha256", "privatePath", "phase", "providerUri"))
            RdpSafTransferFileRecord(
                name = value.getString("name"),
                size = value.exactLong("size"),
                sha256 = value.getString("sha256"),
                privatePath = value.getString("privatePath"),
                phase = enumValue<RdpSafFileCommitPhase>(value.getString("phase")),
                providerUri = value.nullableString("providerUri"),
            )
        }
    }

    private fun readBounded(): ByteArray {
        val output = ByteArrayOutputStream()
        atomic.openRead().use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (output.size() + read > MAX_LEDGER_BYTES) unavailable()
                output.write(buffer, 0, read)
            }
            buffer.fill(0)
        }
        return output.toByteArray()
    }

    private fun decrypt(raw: ByteArray): ByteArray {
        try {
            val envelope = JSONObject(String(raw, StandardCharsets.UTF_8))
            requireKeys(envelope, setOf("schemaVersion", "iv", "ciphertext"))
            if (envelope.exactInt("schemaVersion") != 1) unavailable()
            val iv = Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)
            val ciphertext = Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)
            if (iv.size != 12 || ciphertext.size < 16 || ciphertext.size > MAX_LEDGER_BYTES) unavailable()
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

    private fun ensureSafePath(existing: Boolean) {
        if (!root.exists() && !root.mkdirs()) unavailable()
        if (!root.isDirectory || Files.isSymbolicLink(root.toPath())) unavailable()
        permissions.path.setMode(root.absolutePath, RDP_SAF_PRIVATE_DIRECTORY_MODE)
        if (file.exists() && (Files.isSymbolicLink(file.toPath()) || !file.isFile ||
                (Files.getAttribute(file.toPath(), "unix:nlink") as Number).toLong() != 1L)
        ) unavailable()
        if (existing) permissions.path.setMode(file.absolutePath, RDP_SAF_PRIVATE_FILE_MODE)
    }

    private fun key(create: Boolean): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
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

    private inline fun <reified T : Enum<T>> enumValue(raw: String): T =
        enumValues<T>().singleOrNull { it.name == raw } ?: unavailable()

    private fun requireKeys(value: JSONObject, expected: Set<String>) {
        if (value.keys().asSequence().toSet() != expected) unavailable()
    }

    private fun JSONObject.nullableString(key: String): String? =
        if (isNull(key)) null else get(key) as? String ?: unavailable()

    private fun JSONObject.exactInt(key: String): Int = get(key) as? Int ?: unavailable()
    private fun JSONObject.exactLong(key: String): Long = when (val value = get(key)) {
        is Int -> value.toLong()
        is Long -> value
        else -> unavailable()
    }

    private fun unavailable(): Nothing = throw IllegalStateException("saf_transfer_unavailable")

    companion object {
        private const val DIRECTORY = "rdp-saf-transfers-v1"
        private const val FILE = "journal.enc"
        private const val KEY_ALIAS = "larenor_rdp_saf_transfers_key_v1"
        private const val AAD = "larenor.rdp-saf-transfers.v1"
        private const val MAX_LEDGER_BYTES = 256 * 1024
    }
}

internal class RdpSafTransferJournal(
    private val store: RdpSafTransferStore,
) {
    @Synchronized
    fun snapshot(): RdpSafTransferRecord? = store.read()

    @Synchronized
    fun requirePrepareAllowed(identity: RdpSafTransferIdentity) {
        val existing = store.read() ?: return
        if (existing.phase != RdpSafTransferPhase.DISCARDED ||
            existing.identity.transferId == identity.transferId
        ) unavailable()
    }

    @Synchronized
    fun create(identity: RdpSafTransferIdentity, mirrorRoot: File): RdpSafTransferRecord {
        val existing = store.read()
        if (existing != null && existing.phase != RdpSafTransferPhase.DISCARDED
        ) unavailable()
        val created = RdpSafTransferRecord(
            identity = identity,
            mirrorRoot = mirrorRoot.canonicalPath,
            phase = RdpSafTransferPhase.PREPARING,
        )
        store.replace(created)
        return created
    }

    @Synchronized
    fun prepared(identity: RdpSafTransferIdentity, files: List<RdpSafSealedFile>): RdpSafTransferRecord {
        val current = exact(identity, RdpSafTransferPhase.PREPARING)
        val next = current.copy(
            phase = RdpSafTransferPhase.SESSION_ACTIVE,
            toRemote = files.map(::fileRecord),
        )
        store.replace(next)
        return next
    }

    @Synchronized
    fun closeRequested(identity: RdpSafTransferIdentity): RdpSafTransferRecord {
        val current = exact(identity, RdpSafTransferPhase.SESSION_ACTIVE)
        return persist(current.copy(phase = RdpSafTransferPhase.CLOSE_REQUESTED))
    }

    @Synchronized
    fun sealed(
        identity: RdpSafTransferIdentity,
        closeReceiptId: String,
        files: List<RdpSafSealedFile>,
    ): RdpSafTransferRecord {
        val current = exact(identity, RdpSafTransferPhase.CLOSE_REQUESTED)
        require(closeReceiptId.matches(Regex("[0-9a-f]{32}")))
        return persist(current.copy(
            phase = RdpSafTransferPhase.SEALED,
            closeReceiptId = closeReceiptId,
            fromRemote = files.map(::fileRecord),
        ))
    }

    @Synchronized
    fun markUnknown(identity: RdpSafTransferIdentity): RdpSafTransferRecord {
        val current = exact(identity)
        if (current.phase in setOf(
                RdpSafTransferPhase.COMPLETE,
                RdpSafTransferPhase.DISCARD_INTENT,
                RdpSafTransferPhase.DISCARDED,
            )
        ) {
            return current
        }
        return persist(current.copy(phase = RdpSafTransferPhase.UNKNOWN))
    }

    @Synchronized
    fun beginFileCommit(identity: RdpSafTransferIdentity, name: String): RdpSafTransferFileRecord {
        return updateFile(identity, name, setOf(RdpSafFileCommitPhase.SEALED_PRIVATE)) {
            it.copy(phase = RdpSafFileCommitPhase.SAF_COMMIT_INTENT)
        }
    }

    /** Must be durable before DocumentsContract.createDocument. */
    @Synchronized
    fun createDispatched(identity: RdpSafTransferIdentity, name: String): RdpSafTransferFileRecord {
        return updateFile(identity, name, setOf(RdpSafFileCommitPhase.SAF_COMMIT_INTENT)) {
            it.copy(phase = RdpSafFileCommitPhase.SAF_CREATE_DISPATCHED)
        }
    }

    @Synchronized
    fun created(
        identity: RdpSafTransferIdentity,
        name: String,
        providerUri: String,
    ): RdpSafTransferFileRecord {
        require(providerUri.startsWith("content://") && providerUri.length <= 4096)
        return updateFile(identity, name, setOf(RdpSafFileCommitPhase.SAF_CREATE_DISPATCHED)) {
            it.copy(phase = RdpSafFileCommitPhase.SAF_CREATED, providerUri = providerUri)
        }
    }

    /** Must be durable before opening a provider descriptor for write. */
    @Synchronized
    fun writeDispatched(identity: RdpSafTransferIdentity, name: String): RdpSafTransferFileRecord {
        return updateFile(identity, name, setOf(RdpSafFileCommitPhase.SAF_CREATED)) {
            it.copy(phase = RdpSafFileCommitPhase.SAF_WRITE_DISPATCHED)
        }
    }

    @Synchronized
    fun verified(identity: RdpSafTransferIdentity, name: String): RdpSafTransferRecord {
        updateFile(identity, name, setOf(RdpSafFileCommitPhase.SAF_WRITE_DISPATCHED)) {
            it.copy(phase = RdpSafFileCommitPhase.SAF_VERIFIED)
        }
        val current = exact(identity, RdpSafTransferPhase.SEALED)
        return if (current.fromRemote.all { it.phase == RdpSafFileCommitPhase.SAF_VERIFIED }) {
            persist(current.copy(phase = RdpSafTransferPhase.COMPLETE))
        } else current
    }

    /** Explicit save of an empty sealed receive set is still a durable terminal decision. */
    @Synchronized
    fun completeEmpty(identity: RdpSafTransferIdentity): RdpSafTransferRecord {
        val current = exact(identity, RdpSafTransferPhase.SEALED)
        if (current.fromRemote.isNotEmpty()) unavailable()
        return persist(current.copy(phase = RdpSafTransferPhase.COMPLETE))
    }

    @Synchronized
    fun fileUnknown(identity: RdpSafTransferIdentity, name: String): RdpSafTransferRecord {
        updateFile(identity, name, RdpSafFileCommitPhase.entries.toSet()) {
            it.copy(phase = RdpSafFileCommitPhase.UNKNOWN)
        }
        val current = exact(identity)
        return persist(current.copy(phase = RdpSafTransferPhase.UNKNOWN))
    }

    /** Readback-only recovery; callers must prove the exact one provider document and hash. */
    @Synchronized
    fun recoveredVerified(
        identity: RdpSafTransferIdentity,
        name: String,
        providerUri: String,
    ): RdpSafTransferRecord {
        require(providerUri.startsWith("content://") && providerUri.length <= 4096)
        val current = exact(identity)
        if (current.phase !in setOf(RdpSafTransferPhase.SEALED, RdpSafTransferPhase.UNKNOWN)) unavailable()
        val index = current.fromRemote.indexOfFirst { it.name == name }
        if (index < 0 || current.fromRemote[index].phase !in setOf(
                RdpSafFileCommitPhase.SAF_CREATE_DISPATCHED,
                RdpSafFileCommitPhase.SAF_CREATED,
                RdpSafFileCommitPhase.SAF_WRITE_DISPATCHED,
                RdpSafFileCommitPhase.UNKNOWN,
            )
        ) unavailable()
        val files = current.fromRemote.toMutableList().also {
            it[index] = it[index].copy(
                phase = RdpSafFileCommitPhase.SAF_VERIFIED,
                providerUri = providerUri,
            )
        }
        val nextPhase = when {
            files.all { it.phase == RdpSafFileCommitPhase.SAF_VERIFIED } -> RdpSafTransferPhase.COMPLETE
            files.all {
                it.phase in setOf(
                    RdpSafFileCommitPhase.SEALED_PRIVATE,
                    RdpSafFileCommitPhase.SAF_VERIFIED,
                )
            } -> RdpSafTransferPhase.SEALED
            else -> RdpSafTransferPhase.UNKNOWN
        }
        return persist(current.copy(phase = nextPhase, fromRemote = files))
    }

    @Synchronized
    fun recover(processEpoch: String): RdpSafTransferRecord? {
        val current = store.read() ?: return null
        if (current.identity.processEpoch == processEpoch) return current
        if (current.phase in setOf(
                RdpSafTransferPhase.PREPARING,
                RdpSafTransferPhase.SESSION_ACTIVE,
                RdpSafTransferPhase.CLOSE_REQUESTED,
            )
        ) {
            val unknown = current.copy(phase = RdpSafTransferPhase.UNKNOWN)
            store.replace(unknown)
            return unknown
        }
        return current
    }

    @Synchronized
    fun read(identity: RdpSafTransferIdentity): RdpSafTransferRecord = exact(identity)

    @Synchronized
    fun beginDiscard(identity: RdpSafTransferIdentity): RdpSafTransferRecord {
        val current = exact(identity)
        if (current.phase !in setOf(
                RdpSafTransferPhase.SEALED,
                RdpSafTransferPhase.COMPLETE,
            )
        ) unavailable()
        return persist(current.copy(phase = RdpSafTransferPhase.DISCARD_INTENT))
    }

    @Synchronized
    fun discarded(identity: RdpSafTransferIdentity): RdpSafTransferRecord {
        val current = exact(identity, RdpSafTransferPhase.DISCARD_INTENT)
        return persist(current.copy(phase = RdpSafTransferPhase.DISCARDED))
    }

    @Synchronized
    fun clearTerminal(identity: RdpSafTransferIdentity) {
        val current = exact(identity)
        if (current.phase !in setOf(RdpSafTransferPhase.COMPLETE, RdpSafTransferPhase.DISCARDED)) {
            unavailable()
        }
        store.clear(identity.transferId)
    }

    private fun updateFile(
        identity: RdpSafTransferIdentity,
        name: String,
        allowed: Set<RdpSafFileCommitPhase>,
        transform: (RdpSafTransferFileRecord) -> RdpSafTransferFileRecord,
    ): RdpSafTransferFileRecord {
        val current = exact(identity, RdpSafTransferPhase.SEALED)
        val index = current.fromRemote.indexOfFirst { it.name == name }
        if (index < 0 || current.fromRemote[index].phase !in allowed) unavailable()
        val updatedFile = transform(current.fromRemote[index])
        val files = current.fromRemote.toMutableList().also { it[index] = updatedFile }
        store.replace(current.copy(fromRemote = files))
        return updatedFile
    }

    private fun exact(
        identity: RdpSafTransferIdentity,
        requiredPhase: RdpSafTransferPhase? = null,
    ): RdpSafTransferRecord {
        val current = store.read() ?: unavailable()
        if (current.identity != identity || requiredPhase != null && current.phase != requiredPhase) unavailable()
        return current
    }

    private fun persist(value: RdpSafTransferRecord): RdpSafTransferRecord {
        store.replace(value)
        return value
    }

    private fun fileRecord(value: RdpSafSealedFile) = RdpSafTransferFileRecord(
        name = value.name,
        size = value.size,
        sha256 = value.sha256,
        privatePath = value.file.canonicalPath,
        phase = RdpSafFileCommitPhase.SEALED_PRIVATE,
    )

    private fun unavailable(): Nothing = throw IllegalStateException("saf_transfer_unavailable")
}
