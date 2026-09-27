package com.ersingundem.larenor.notifications

import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit

internal sealed interface DeliveryPullResult {
    data class Success(val events: List<LocalNotificationRenderEvent>, val more: Boolean) : DeliveryPullResult
    data object AuthorityRejected : DeliveryPullResult
    data object AuthorityChanged : DeliveryPullResult
    data object TransientFailure : DeliveryPullResult
    data object ProtocolRejected : DeliveryPullResult
}

/** Credential-isolated GET transport for the projection-only delivery endpoint. */
internal class LocalNotificationDeliveryTransport {
    companion object {
        private const val MAX_BYTES = 65_536
        private const val LIMIT = 50
        private const val CREDENTIAL_HEADER = "X-Larenor-Delivery-Credential"

        fun validateBaseUrl(value: String): String {
            val trimmed = value.trim()
            require(trimmed == value && !value.any(Char::isWhitespace) && '\\' !in value)
            val url = value.toHttpUrlOrNull() ?: throw IllegalArgumentException()
            require(url.scheme == "https")
            require(url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null)
            require(url.pathSegments.none { it == "." || it == ".." || '\\' in it || it.any { char -> char.code < 32 || char.code == 127 } })
            return url.newBuilder().query(null).fragment(null).build().toString().removeSuffix("/")
        }
    }

    private val client = OkHttpClient.Builder()
        .cookieJar(CookieJar.NO_COOKIES)
        .authenticator(Authenticator.NONE)
        .proxyAuthenticator(Authenticator.NONE)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val request = chain.request()
            if (request.method != "GET" || request.header("Authorization") != null ||
                request.header("Cookie") != null || request.header("Proxy-Authorization") != null ||
                request.headers(CREDENTIAL_HEADER).size != 1
            ) throw IOException("delivery_request_rejected")
            chain.proceed(request)
        }
        .build()

    fun pull(record: LocalNotificationDeliveryRecord): DeliveryPullResult {
        val url = try {
            endpoint(record)
        } catch (_: Exception) {
            return DeliveryPullResult.ProtocolRejected
        }
        val request = Request.Builder().url(url)
            .header("Accept", "application/json")
            .header(CREDENTIAL_HEADER, record.credential)
            .get().build()
        return try {
            client.newCall(request).execute().use { response ->
                when (response.code) {
                    200 -> parse(record, response.header("Content-Type"), response.header("Content-Encoding"),
                        response.body.byteStream().use(::readBounded))
                    401, 403, 410 -> DeliveryPullResult.AuthorityRejected
                    404, 409 -> DeliveryPullResult.AuthorityChanged
                    408, 425, 429, in 500..599 -> DeliveryPullResult.TransientFailure
                    else -> DeliveryPullResult.ProtocolRejected
                }
            }
        } catch (_: IOException) {
            DeliveryPullResult.TransientFailure
        } catch (_: Exception) {
            DeliveryPullResult.ProtocolRejected
        }
    }

    private fun endpoint(record: LocalNotificationDeliveryRecord): HttpUrl {
        val base = validateBaseUrl(record.baseUrl).toHttpUrlOrNull() ?: throw IllegalArgumentException()
        return base.newBuilder()
            .addPathSegments("api/v1/local-notifications")
            .addPathSegment(record.coreId)
            .addPathSegment(record.homeId)
            .addPathSegment("delivery-leases")
            .addPathSegment(record.leaseId)
            .addPathSegment("events")
            .addQueryParameter("expectedLeaseRevision", record.leaseRevision.toString())
            .addQueryParameter("after", record.cursor.toString())
            .addQueryParameter("limit", LIMIT.toString())
            .build()
    }

    private fun parse(
        record: LocalNotificationDeliveryRecord,
        contentType: String?,
        contentEncoding: String?,
        body: ByteArray,
    ): DeliveryPullResult {
        if (contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json" ||
            contentEncoding?.lowercase() !in setOf(null, "identity")
        ) return DeliveryPullResult.ProtocolRejected
        val root = JSONObject(String(body, Charsets.UTF_8))
        require(root.keys().asSequence().toSet() == setOf(
            "schemaVersion", "scope", "leaseRevision", "subscriptionRevision", "events", "nextAfter",
        ))
        require(exactInt(root, "schemaVersion") == 1)
        require(exactLong(root, "leaseRevision") == record.leaseRevision)
        require(exactLong(root, "subscriptionRevision") == record.subscriptionRevision)
        val scope = root.get("scope") as? JSONObject ?: throw IllegalArgumentException()
        require(scope.keys().asSequence().toSet() == setOf("schemaVersion", "coreId", "homeId"))
        require(exactInt(scope, "schemaVersion") == 1 && exactString(scope, "coreId") == record.coreId &&
            exactString(scope, "homeId") == record.homeId)
        val rawEvents = root.get("events") as? org.json.JSONArray ?: throw IllegalArgumentException()
        require(rawEvents.length() <= LIMIT)
        val events = ArrayList<LocalNotificationRenderEvent>(rawEvents.length())
        var previous = record.cursor
        for (index in 0 until rawEvents.length()) {
            val event = parseEvent(rawEvents.get(index) as? JSONObject ?: throw IllegalArgumentException())
            require(event.sequence > previous)
            previous = event.sequence
            events.add(event)
        }
        val nextAfter = root.optNullableLong("nextAfter")
        require(nextAfter == null || events.isNotEmpty() && nextAfter == events.last().sequence)
        return DeliveryPullResult.Success(events, nextAfter != null)
    }

    private fun parseEvent(value: JSONObject): LocalNotificationRenderEvent {
        require(value.keys().asSequence().toSet() == setOf("id", "sequence", "sensitivity", "publicProjection"))
        val id = exactString(value, "id")
        val sequence = exactLong(value, "sequence")
        val sensitivity = exactString(value, "sensitivity")
        require(LocalNotificationRenderer.HEX_32.matches(id) && sequence > 0)
        require(sensitivity == "public" || sensitivity == "private")
        val projection = value.get("publicProjection") as? JSONObject ?: throw IllegalArgumentException()
        require(projection.keys().asSequence().toSet() == setOf("title", "body", "target", "redacted"))
        val title = safeText(exactString(projection, "title"), 120, false)
        val body = safeText(exactString(projection, "body"), 1024, true)
        val redacted = projection.get("redacted") as? Boolean ?: throw IllegalArgumentException()
        val target = when (val raw = projection.get("target")) {
            JSONObject.NULL -> null
            is String -> raw
            else -> throw IllegalArgumentException()
        }
        val private = sensitivity == "private"
        if (private) {
            require(redacted && title == "Larenor" && body.isEmpty() && target == null)
        } else {
            require(!redacted && target != null && safeTarget(target))
        }
        return LocalNotificationRenderEvent(id, sequence, title, body, private)
    }

    private fun safeText(value: String, maximum: Int, empty: Boolean): String {
        require(value.length <= maximum && (empty || value.isNotEmpty()) &&
            value.none { it.code < 32 || it.code == 127 || it.code in 0xD800..0xDFFF })
        return value
    }

    private fun safeTarget(value: String): Boolean = value.length in 1..256 && value.startsWith('/') &&
        !value.startsWith("//") && '?' !in value && '#' !in value && '\\' !in value &&
        value.split('/').drop(1).all { it.isNotEmpty() && it != "." && it != ".." }

    private fun readBounded(stream: java.io.InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            if (output.size() + count > MAX_BYTES) throw IllegalArgumentException("delivery_response_too_large")
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun exactString(value: JSONObject, name: String): String =
        value.get(name) as? String ?: throw IllegalArgumentException()

    private fun exactInt(value: JSONObject, name: String): Int =
        value.get(name) as? Int ?: throw IllegalArgumentException()

    private fun exactLong(value: JSONObject, name: String): Long = when (val raw = value.get(name)) {
        is Int -> raw.toLong()
        is Long -> raw
        else -> throw IllegalArgumentException()
    }

    private fun JSONObject.optNullableLong(name: String): Long? = when (val raw = get(name)) {
        JSONObject.NULL -> null
        is Int -> raw.toLong()
        is Long -> raw
        else -> throw IllegalArgumentException()
    }
}
