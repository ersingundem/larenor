package com.ersingundem.larenor.updater

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URI
import java.security.MessageDigest
import java.time.OffsetDateTime

class UpdateFailure(val code: String) : Exception("Client update unavailable")

data class ClientRelease(
    val applicationId: String, val versionCode: Long, val versionName: String,
    val certificateSha256: String, val apkSha256: String, val sizeBytes: Long,
    val minSdk: Int, val downloadPath: String,
) {
    companion object {
        const val APPLICATION_ID = "com.ersingundem.larenor"
        const val MAX_BYTES = 512L * 1024 * 1024
        private val hex = Regex("[a-fA-F0-9]{64}")
        fun parse(raw: Any?): ClientRelease {
            if (raw !is Map<*, *> || raw.size != 12) throw UpdateFailure("invalidMetadata")
            fun string(key: String, max: Int): String {
                val value = raw[key] as? String ?: throw UpdateFailure("invalidMetadata")
                if (value.length > max || value.any { it.code < 32 && it != '\n' && it != '\t' }) throw UpdateFailure("invalidMetadata")
                return value
            }
            fun integer(key: String): Long = when(val v = raw[key]) {
                is Int -> v.toLong(); is Long -> v; else -> throw UpdateFailure("invalidMetadata")
            }
            val version = integer("versionCode")
            val name = string("versionName", 80)
            val size = integer("sizeBytes")
            val min = integer("minSdk")
            val cert = string("certificateSha256", 64)
            val hash = string("apkSha256", 64)
            val path = string("downloadPath", 100)
            val published = string("publishedAt", 64)
            if (integer("schemaVersion") != 1L || string("applicationId", 100) != APPLICATION_ID ||
                version !in 1..Int.MAX_VALUE.toLong() || name.isBlank() || size !in 1..MAX_BYTES ||
                min != 26L || !hex.matches(cert) || !hex.matches(hash) ||
                path != "/api/v1/client/releases/$version/apk" ||
                !Regex("[a-fA-F0-9]{40}").matches(string("commit", 40))) throw UpdateFailure("invalidMetadata")
            try { OffsetDateTime.parse(published) } catch (_: Exception) { throw UpdateFailure("invalidMetadata") }
            string("releaseNotes", 12000)
            return ClientRelease(APPLICATION_ID, version, name, cert.lowercase(), hash.lowercase(), size, min.toInt(), path)
        }
    }
}

data class InstalledClient(val applicationId: String, val versionCode: Long, val versionName: String,
                           val certificates: Set<String>, val sdkInt: Int)
data class ArchiveIdentity(val applicationId: String, val versionCode: Long, val versionName: String,
                           val minSdk: Int, val certificates: Set<String>, val cryptographicallyVerified: Boolean)

object UpdateValidation {
    fun preflight(release: ClientRelease, installed: InstalledClient) {
        if (installed.applicationId != ClientRelease.APPLICATION_ID || release.applicationId != installed.applicationId ||
            release.versionCode <= installed.versionCode || release.minSdk > installed.sdkInt ||
            installed.certificates.size != 1 || release.certificateSha256 !in installed.certificates) throw UpdateFailure("incompatible")
    }
    fun archive(release: ClientRelease, installed: InstalledClient, archive: ArchiveIdentity) {
        preflight(release, installed)
        if (!archive.cryptographicallyVerified || archive.applicationId != installed.applicationId ||
            archive.versionCode != release.versionCode || archive.versionName != release.versionName ||
            archive.minSdk != release.minSdk || archive.certificates != installed.certificates) throw UpdateFailure("verification")
    }
    fun url(baseUrl: String, release: ClientRelease): HttpUrl {
        if (baseUrl.length > 2048 || baseUrl.any { it.isWhitespace() || it == '\\' || it.code < 32 }) throw UpdateFailure("invalidMetadata")
        val raw = try { URI(baseUrl) } catch (_: Exception) { throw UpdateFailure("invalidMetadata") }
        // Avoid parser/proxy normalization disagreement. The configured prefix
        // may have ordinary path segments but no escaped separators or dots.
        if (raw.rawUserInfo != null || raw.rawQuery != null || raw.rawFragment != null ||
            raw.rawPath.orEmpty().contains('%') || raw.rawPath.orEmpty().split('/').any { it == "." || it == ".." }) throw UpdateFailure("invalidMetadata")
        val base = baseUrl.toHttpUrlOrNull() ?: throw UpdateFailure("invalidMetadata")
        if (base.scheme !in setOf("http", "https") || base.username.isNotEmpty() || base.password.isNotEmpty()) throw UpdateFailure("invalidMetadata")
        return base.newBuilder().encodedPath(base.encodedPath.trimEnd('/') + release.downloadPath).build()
    }
}

fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
