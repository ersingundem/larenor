package com.ersingundem.larenor.notifications

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class LocalNotificationDeliveryRecord(
    val phase: String,
    val baseUrl: String,
    val coreId: String,
    val homeId: String,
    val bindingId: String,
    val subscriptionId: String,
    val subscriptionRevision: Long,
    val leaseId: String,
    val leaseRevision: Long,
    val credential: String,
    val credentialFingerprint: String,
    val expiresAt: Double,
    val cursor: Long,
) {
    val active: Boolean get() = phase == "active" && leaseRevision > 0
}

/** Keeps delivery credentials encrypted by a non-exportable Android Keystore key. */
internal class LocalNotificationDeliveryStore(
    context: Context,
    // Tests can supply a local AES key; production always uses Android Keystore.
    private val testKeyProvider: ((Boolean) -> SecretKey)? = null,
) {
    companion object {
        private const val STORE = "larenor_local_notification_delivery_store_v1"
        private const val KEY_ALIAS = "larenor_local_notification_delivery_key_v1"
        private const val KEY_CIPHERTEXT = "ciphertext"
        private const val KEY_IV = "iv"
        private const val AAD = "larenor.local-notification-delivery.v1"
        private val lock = Any()
    }

    private val preferences = context.applicationContext.getSharedPreferences(STORE, Context.MODE_PRIVATE)

    fun hasSealedRecord(): Boolean = preferences.contains(KEY_CIPHERTEXT) || preferences.contains(KEY_IV)

    fun load(): LocalNotificationDeliveryRecord? = synchronized(lock) {
        val ciphertext = preferences.getString(KEY_CIPHERTEXT, null)
        val iv = preferences.getString(KEY_IV, null)
        if (ciphertext == null && iv == null) return@synchronized null
        if (ciphertext == null || iv == null) return@synchronized invalidate()
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, testKeyProvider?.invoke(false) ?: key(false), GCMParameterSpec(128, decode(iv)))
            cipher.updateAAD(AAD.toByteArray(Charsets.UTF_8))
            decodeRecord(JSONObject(String(cipher.doFinal(decode(ciphertext)), Charsets.UTF_8)))
        } catch (_: Exception) {
            invalidate()
        }
    }

    fun save(record: LocalNotificationDeliveryRecord) = synchronized(lock) {
        val plain = encodeRecord(record).toString().toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, testKeyProvider?.invoke(true) ?: key(true))
        cipher.updateAAD(AAD.toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(plain)
        if (!preferences.edit()
                .putString(KEY_IV, encode(cipher.iv))
                .putString(KEY_CIPHERTEXT, encode(encrypted))
                .commit()
        ) throw NotificationRejected("unavailable")
    }

    fun updateCursor(expectedLeaseId: String, expectedRevision: Long, cursor: Long) = synchronized(lock) {
        val record = load() ?: throw NotificationRejected("stale")
        if (!record.active || record.leaseId != expectedLeaseId || record.leaseRevision != expectedRevision ||
            cursor < record.cursor
        ) throw NotificationRejected("stale")
        save(record.copy(cursor = cursor))
    }

    fun matches(expectedLeaseId: String, expectedRevision: Long): Boolean = synchronized(lock) {
        val record = load() ?: return@synchronized false
        record.active && record.leaseId == expectedLeaseId && record.leaseRevision == expectedRevision
    }

    fun clearIf(expectedLeaseId: String, expectedRevision: Long): Boolean = synchronized(lock) {
        val record = load() ?: return@synchronized false
        if (record.leaseId != expectedLeaseId || record.leaseRevision != expectedRevision) {
            return@synchronized false
        }
        clear()
        true
    }

    fun clearPending(
        expectedLeaseId: String,
        expectedFingerprint: String,
        expectedSubscriptionRevision: Long,
    ): Boolean = synchronized(lock) {
        val record = load() ?: return@synchronized false
        if (record.phase != "pending" || record.leaseId != expectedLeaseId ||
            record.credentialFingerprint != expectedFingerprint ||
            record.subscriptionRevision != expectedSubscriptionRevision
        ) return@synchronized false
        clear()
        true
    }

    fun clear() = synchronized(lock) {
        if (!preferences.edit().clear().commit()) throw NotificationRejected("unavailable")
    }

    private fun invalidate(): LocalNotificationDeliveryRecord? {
        preferences.edit().clear().commit()
        runCatching {
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (keyStore.containsAlias(KEY_ALIAS)) keyStore.deleteEntry(KEY_ALIAS)
        }
        return null
    }

    private fun key(create: Boolean): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) throw IllegalStateException("delivery_key_missing")
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

    private fun encodeRecord(value: LocalNotificationDeliveryRecord) = JSONObject()
        .put("schemaVersion", 1)
        .put("phase", value.phase)
        .put("baseUrl", value.baseUrl)
        .put("coreId", value.coreId)
        .put("homeId", value.homeId)
        .put("bindingId", value.bindingId)
        .put("subscriptionId", value.subscriptionId)
        .put("subscriptionRevision", value.subscriptionRevision)
        .put("leaseId", value.leaseId)
        .put("leaseRevision", value.leaseRevision)
        .put("credential", value.credential)
        .put("credentialFingerprint", value.credentialFingerprint)
        .put("expiresAt", value.expiresAt)
        .put("cursor", value.cursor)

    private fun decodeRecord(value: JSONObject): LocalNotificationDeliveryRecord {
        require(value.keys().asSequence().toSet() == setOf(
            "schemaVersion", "phase", "baseUrl", "coreId", "homeId", "bindingId",
            "subscriptionId", "subscriptionRevision", "leaseId", "leaseRevision", "credential",
            "credentialFingerprint", "expiresAt", "cursor",
        ))
        require(value.get("schemaVersion") is Int && value.get("schemaVersion") == 1)
        val phase = exactString(value, "phase")
        require(phase == "pending" || phase == "active")
        val record = LocalNotificationDeliveryRecord(
            phase = phase,
            baseUrl = exactString(value, "baseUrl"),
            coreId = exactString(value, "coreId"),
            homeId = exactString(value, "homeId"),
            bindingId = exactString(value, "bindingId"),
            subscriptionId = exactString(value, "subscriptionId"),
            subscriptionRevision = exactLong(value, "subscriptionRevision"),
            leaseId = exactString(value, "leaseId"),
            leaseRevision = exactLong(value, "leaseRevision"),
            credential = exactString(value, "credential"),
            credentialFingerprint = exactString(value, "credentialFingerprint"),
            expiresAt = exactNumber(value, "expiresAt"),
            cursor = exactLong(value, "cursor"),
        )
        require(LocalNotificationRenderer.HEX_32.matches(record.coreId))
        require(LocalNotificationRenderer.HEX_32.matches(record.homeId))
        require(LocalNotificationRenderer.HEX_64.matches(record.bindingId))
        require(LocalNotificationRenderer.HEX_32.matches(record.subscriptionId))
        require(LocalNotificationRenderer.HEX_32.matches(record.leaseId))
        require(LocalNotificationRenderer.HEX_64.matches(record.credentialFingerprint))
        require(Regex("^[A-Za-z0-9_-]{43}$").matches(record.credential))
        require(record.subscriptionRevision > 0 && record.leaseRevision >= 0 &&
            record.expiresAt.isFinite() && record.expiresAt > 0 && record.cursor >= 0)
        if (record.phase == "pending") require(record.leaseRevision == 0L)
        else require(record.leaseRevision > 0)
        return record
    }

    private fun exactString(value: JSONObject, name: String): String =
        value.get(name) as? String ?: throw IllegalArgumentException("invalid_$name")

    private fun exactLong(value: JSONObject, name: String): Long = when (val raw = value.get(name)) {
        is Int -> raw.toLong()
        is Long -> raw
        else -> throw IllegalArgumentException("invalid_$name")
    }

    private fun exactNumber(value: JSONObject, name: String): Double = when (val raw = value.get(name)) {
        is Int -> raw.toDouble()
        is Long -> raw.toDouble()
        is Double -> raw
        else -> throw IllegalArgumentException("invalid_$name")
    }

    private fun encode(value: ByteArray): String = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun decode(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)
}
