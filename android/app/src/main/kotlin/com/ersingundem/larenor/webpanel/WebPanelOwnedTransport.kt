package com.ersingundem.larenor.webpanel

import android.net.Uri
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.ByteArrayInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal interface WebPanelRequestTransport {
    fun fetch(uri: Uri, method: String): WebResourceResponse
    fun close()
}

/**
 * Owns anonymous WebPanel subresource GETs. WebView request headers, cookies,
 * credentials and bodies never enter this transport. Redirects are resolved
 * explicitly so every target is checked before another socket is opened.
 */
internal class WebPanelOwnedHttpTransport(
    private val firewall: WebRequestFirewall,
    private val maxRedirects: Int = 3,
    private val maxResponseBytes: Long = 16L * 1024 * 1024,
    private val client: OkHttpClient = client(),
) : WebPanelRequestTransport {
    private val retired = AtomicBoolean(false)
    private val calls = ConcurrentHashMap.newKeySet<Call>()

    init {
        require(maxRedirects in 0..3)
        require(maxResponseBytes in 1..(25L * 1024 * 1024))
    }

    override fun fetch(uri: Uri, method: String): WebResourceResponse {
        if (retired.get()) return terminalResponse(410, "Gone")
        if (method != "GET" || !firewall.allows(uri)) return firewall.blockedResponse()
        var target = uri.toString().toHttpUrlOrNull() ?: return firewall.blockedResponse()
        repeat(maxRedirects + 1) { redirectCount ->
            if (retired.get()) return terminalResponse(410, "Gone")
            val call = client.newCall(Request.Builder().url(target).get().build())
            calls += call
            if (retired.get()) {
                calls -= call
                call.cancel()
                return terminalResponse(410, "Gone")
            }
            val response = try {
                call.execute()
            } catch (_: IOException) {
                calls -= call
                return if (retired.get()) {
                    terminalResponse(410, "Gone")
                } else {
                    terminalResponse(502, "Bad Gateway")
                }
            }
            if (retired.get()) {
                response.close()
                calls -= call
                return terminalResponse(410, "Gone")
            }
            if (response.code in 300..399) {
                val location = response.header("Location")
                response.close()
                calls -= call
                if (redirectCount == maxRedirects || location == null) {
                    return terminalResponse(508, "Loop Detected")
                }
                val next = target.resolve(location) ?: return firewall.blockedResponse()
                if (!firewall.allows(Uri.parse(next.toString()))) return firewall.blockedResponse()
                target = next
            } else {
                return response.toWebResourceResponse(call)
            }
        }
        return terminalResponse(508, "Loop Detected")
    }

    private fun Response.toWebResourceResponse(call: Call): WebResourceResponse {
        val body = body
        if (body.contentLength() > maxResponseBytes) {
            close()
            calls -= call
            return terminalResponse(413, "Content Too Large")
        }
        val contentType = body.contentType()
        val mimeType = contentType?.let { "${it.type}/${it.subtype}" } ?: "application/octet-stream"
        val encoding = contentType?.charset()?.name() ?: "UTF-8"
        val data = BoundedResponseInputStream(
            body.byteStream(),
            maxResponseBytes,
            finished = {
                close()
                calls -= call
            },
        )
        return WebResourceResponse(
            mimeType,
            encoding,
            code,
            message.ifBlank { "HTTP $code" },
            responseHeaders(),
            data,
        )
    }

    private fun Response.responseHeaders(): Map<String, String> {
        val allowed = linkedMapOf<String, String>()
        for (name in listOf("Cache-Control", "Content-Language", "ETag", "Last-Modified")) {
            header(name)?.takeIf { it.length <= 1024 && it.none(Char::isISOControl) }
                ?.let { allowed[name] = it }
        }
        allowed["X-Content-Type-Options"] = "nosniff"
        return Collections.unmodifiableMap(allowed)
    }

    override fun close() {
        if (!retired.compareAndSet(false, true)) return
        calls.toList().forEach(Call::cancel)
        calls.clear()
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
    }

    companion object {
        private fun client() = OkHttpClient.Builder()
            .cookieJar(CookieJar.NO_COOKIES)
            .authenticator(Authenticator.NONE)
            .proxyAuthenticator(Authenticator.NONE)
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .cache(null)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .callTimeout(15, TimeUnit.SECONDS)
            .build()

        private fun terminalResponse(code: Int, reason: String) = WebResourceResponse(
            "text/plain",
            "UTF-8",
            code,
            reason,
            mapOf(
                "Cache-Control" to "no-store",
                "Content-Security-Policy" to "default-src 'none'; sandbox",
                "Referrer-Policy" to "no-referrer",
                "X-Content-Type-Options" to "nosniff",
            ),
            ByteArrayInputStream(ByteArray(0)),
        )
    }
}

private class BoundedResponseInputStream(
    source: InputStream,
    private val maximum: Long,
    private val finished: () -> Unit,
) : FilterInputStream(source) {
    private val closed = AtomicBoolean(false)
    private var consumed = 0L

    override fun read(): Int {
        val value = super.read()
        if (value < 0) finish() else count(1)
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val read = super.read(buffer, offset, length)
        if (read < 0) finish() else count(read.toLong())
        return read
    }

    private fun count(amount: Long) {
        consumed += amount
        if (consumed > maximum) {
            finish()
            throw IOException("WebPanel response exceeded its bound")
        }
    }

    private fun finish() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { super.close() }
        finished()
    }

    override fun close() = finish()
}

/**
 * Uses the official document-start hook before any page JavaScript. Dedicated
 * and shared workers are disabled; exact-origin ws/wss remains available.
 * Service-worker networking is separately disabled by ServiceWorkerRequestFirewall.
 */
internal class WebPanelDynamicEgressPolicy(
    private val isSupported: (String) -> Boolean = WebViewFeature::isFeatureSupported,
    private val installScript: (WebView, String, Set<String>) -> AutoCloseable = { view, script, origins ->
        val handler = WebViewCompat.addDocumentStartJavaScript(view, script, origins)
        AutoCloseable { handler.remove() }
    },
) {
    fun install(webView: WebView, origins: Set<WebRequestOrigin>): AutoCloseable? {
        if (!isSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) return null
        val originRules = origins.mapTo(linkedSetOf()) { it.documentOrigin() }
        val websocketOrigins = origins.map { it.websocketOrigin() }.sorted()
        val values = websocketOrigins.joinToString(",") { "\"$it\"" }
        val script = """
            (() => {
              'use strict';
              const allowed = new Set([$values]);
              const nativeWebSocket = globalThis.WebSocket;
              const normalize = (value) => {
                const target = new URL(String(value), globalThis.location.href);
                if (target.protocol !== 'ws:' && target.protocol !== 'wss:') throw new DOMException('Blocked', 'SecurityError');
                const port = target.port || (target.protocol === 'wss:' ? '443' : '80');
                return target.protocol + '//' + target.hostname.toLowerCase() + ':' + port;
              };
              class BoundedWebSocket extends nativeWebSocket {
                constructor(url, protocols) {
                  if (!allowed.has(normalize(url))) throw new DOMException('Blocked', 'SecurityError');
                  if (protocols === undefined) super(url); else super(url, protocols);
                }
              }
              const blockedWorker = class { constructor() { throw new DOMException('Blocked', 'SecurityError'); } };
              Object.defineProperty(globalThis, 'WebSocket', { value: BoundedWebSocket, writable: false, configurable: false });
              Object.defineProperty(globalThis, 'Worker', { value: blockedWorker, writable: false, configurable: false });
              Object.defineProperty(globalThis, 'SharedWorker', { value: blockedWorker, writable: false, configurable: false });
            })();
        """.trimIndent()
        return runCatching {
            OnceCloseable(installScript(webView, script, originRules))
        }.getOrNull()
    }

    private fun WebRequestOrigin.documentOrigin(): String {
        val hostValue = if (':' in host) "[$host]" else host
        val defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "$scheme://$hostValue${if (defaultPort) "" else ":$port"}"
    }

    private fun WebRequestOrigin.websocketOrigin(): String {
        val websocketScheme = if (scheme == "https") "wss" else "ws"
        val hostValue = if (':' in host) "[$host]" else host
        return "$websocketScheme://$hostValue:$port"
    }
}

private class OnceCloseable(private val delegate: AutoCloseable) : AutoCloseable {
    private val closed = AtomicBoolean(false)

    override fun close() {
        if (closed.compareAndSet(false, true)) runCatching(delegate::close)
    }
}
