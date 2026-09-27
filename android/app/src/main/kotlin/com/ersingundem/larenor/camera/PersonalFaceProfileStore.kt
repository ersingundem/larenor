package com.ersingundem.larenor.camera

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class PersonalFaceProfile(
    val id: String,
    val createdAtMs: Long,
    val sampleCount: Int,
    val detectorVersion: String,
    val vector: List<Double>,
)

/** Stores one non-security personalization template under Android Keystore. */
internal class PersonalFaceProfileStore(context: Context) {
    companion object {
        private const val STORE = "larenor_personal_face_profile_v1"
        private const val KEY_ALIAS = "larenor_personal_face_profile_key_v1"
        private const val KEY_CIPHERTEXT = "ciphertext"
        private const val KEY_IV = "iv"
        private const val AAD = "larenor.personal-face-profile.v1"
        private val PROFILE_ID = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        private val lock = Any()
    }

    private val preferences = context.applicationContext.getSharedPreferences(STORE, Context.MODE_PRIVATE)

    fun load(): PersonalFaceProfile? = synchronized(lock) {
        val ciphertext = preferences.getString(KEY_CIPHERTEXT, null)
        val iv = preferences.getString(KEY_IV, null)
        if (ciphertext == null && iv == null) return@synchronized null
        if (ciphertext == null || iv == null) return@synchronized invalidate()
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, decode(iv)))
            cipher.updateAAD(AAD.toByteArray(Charsets.UTF_8))
            decodeProfile(JSONObject(String(cipher.doFinal(decode(ciphertext)), Charsets.UTF_8)))
        } catch (_: Exception) {
            invalidate()
        }
    }

    fun save(profile: PersonalFaceProfile) = synchronized(lock) {
        validate(profile)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true))
        cipher.updateAAD(AAD.toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(encodeProfile(profile).toString().toByteArray(Charsets.UTF_8))
        check(
            preferences.edit()
                .putString(KEY_IV, encode(cipher.iv))
                .putString(KEY_CIPHERTEXT, encode(encrypted))
                .commit(),
        )
    }

    fun deleteVerified(expectedId: String): Boolean = synchronized(lock) {
        val current = load() ?: return@synchronized false
        if (current.id != expectedId) return@synchronized false
        if (!preferences.edit().clear().commit()) return@synchronized false
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(KEY_ALIAS)) keyStore.deleteEntry(KEY_ALIAS)
        !preferences.contains(KEY_CIPHERTEXT) &&
            !preferences.contains(KEY_IV) &&
            !keyStore.containsAlias(KEY_ALIAS)
    }

    private fun invalidate(): PersonalFaceProfile? {
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
        if (!create) error("profile_key_missing")
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

    private fun encodeProfile(value: PersonalFaceProfile) = JSONObject()
        .put("schemaVersion", 1)
        .put("id", value.id)
        .put("createdAtMs", value.createdAtMs)
        .put("sampleCount", value.sampleCount)
        .put("detectorVersion", value.detectorVersion)
        .put("vector", JSONArray(value.vector))

    private fun decodeProfile(value: JSONObject): PersonalFaceProfile {
        require(
            value.keys().asSequence().toSet() == setOf(
                "schemaVersion",
                "id",
                "createdAtMs",
                "sampleCount",
                "detectorVersion",
                "vector",
            ),
        )
        require(value.get("schemaVersion") is Int && value.getInt("schemaVersion") == 1)
        val vectorJson = value.getJSONArray("vector")
        val profile = PersonalFaceProfile(
            id = value.getString("id"),
            createdAtMs = value.getLong("createdAtMs"),
            sampleCount = value.getInt("sampleCount"),
            detectorVersion = value.getString("detectorVersion"),
            vector = List(vectorJson.length()) { vectorJson.getDouble(it) },
        )
        validate(profile)
        return profile
    }

    private fun validate(value: PersonalFaceProfile) {
        require(PROFILE_ID.matches(value.id))
        require(value.createdAtMs > 0)
        require(value.sampleCount in 5..32)
        require(Regex("^\\d+\\.\\d+\\.\\d+$").matches(value.detectorVersion))
        require(value.vector.size == 11)
        require(value.vector.all { it.isFinite() && it in -8.0..8.0 })
    }

    private fun encode(value: ByteArray): String = Base64.encodeToString(value, Base64.NO_WRAP)

    private fun decode(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)
}
