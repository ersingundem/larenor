package com.ersingundem.larenor.webpanel

import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Message
import android.view.KeyEvent
import android.view.ViewGroup
import android.webkit.ClientCertRequest
import android.webkit.HttpAuthHandler
import android.webkit.RenderProcessGoneDetail
import android.webkit.SafeBrowsingResponse
import android.webkit.SslErrorHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ServiceWorkerControllerCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayInputStream
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean

internal class RendererRequestFailure : IllegalArgumentException()

internal data class WebRequestOrigin(
    val scheme: String,
    val host: String,
    val port: Int,
) {
    fun matches(uri: Uri): Boolean {
        if (uri.isOpaque || uri.userInfo != null) return false
        val candidateScheme = uri.scheme?.lowercase() ?: return false
        val candidateHost = uri.host?.removeSurrounding("[", "]")?.lowercase() ?: return false
        val candidatePort = when {
            uri.port >= 0 -> uri.port
            candidateScheme == "https" -> 443
            candidateScheme == "http" -> 80
            else -> return false
        }
        return scheme == candidateScheme && host == candidateHost && port == candidatePort
    }

    companion object {
        private val dnsLabel = Regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
        private val ipv6Characters = Regex("^[0-9a-f:.]+$")

        private fun canonicalHost(raw: String): Boolean {
            if (raw.isEmpty() || raw.length > 253 || raw != raw.lowercase() ||
                raw.any { it.isWhitespace() || it.isISOControl() || it in "/?#@%\\[]" }
            ) {
                return false
            }
            if (':' in raw) {
                return ipv6Characters.matches(raw) &&
                    runCatching { InetAddress.getByName(raw) is Inet6Address }.getOrDefault(false)
            }
            if (raw.endsWith('.')) return false
            return raw.split('.').all(dnsLabel::matches)
        }

        fun parse(value: Any?): WebRequestOrigin {
            val values = value as? Map<*, *> ?: throw RendererRequestFailure()
            if (values.keys != setOf("scheme", "host", "port")) throw RendererRequestFailure()
            val scheme = values["scheme"] as? String ?: throw RendererRequestFailure()
            val rawHost = values["host"] as? String ?: throw RendererRequestFailure()
            val port = when (val rawPort = values["port"]) {
                is Int -> rawPort
                is Long -> rawPort.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
                else -> null
            } ?: throw RendererRequestFailure()
            if (scheme !in setOf("http", "https") ||
                rawHost != rawHost.trim() ||
                !canonicalHost(rawHost) ||
                port !in 1..65535
            ) {
                throw RendererRequestFailure()
            }
            return WebRequestOrigin(scheme, rawHost, port)
        }
    }
}

internal class WebRequestFirewall(private val allowedOrigins: Set<WebRequestOrigin>) {
    fun allows(uri: Uri): Boolean = allowedOrigins.any { it.matches(uri) }

    fun allows(rawUrl: String): Boolean = runCatching { allows(Uri.parse(rawUrl)) }.getOrDefault(false)

    fun blockedResponse() = WebResourceResponse(
        "text/plain",
        "UTF-8",
        403,
        "Forbidden",
        mapOf(
            "Cache-Control" to "no-store",
            "Content-Security-Policy" to "default-src 'none'; sandbox",
            "Referrer-Policy" to "no-referrer",
            "X-Content-Type-Options" to "nosniff",
        ),
        ByteArrayInputStream(ByteArray(0)),
    )
}

/** Process-global fail-closed policy because Service Workers outlive WebViews. */
internal class ServiceWorkerRequestFirewall(
    private val isSupported: (String) -> Boolean = WebViewFeature::isFeatureSupported,
    private val closeNetwork: () -> Unit = {
        val settings = ServiceWorkerControllerCompat.getInstance().serviceWorkerWebSettings
        settings.setBlockNetworkLoads(true)
        settings.setAllowContentAccess(false)
        settings.setAllowFileAccess(false)
    },
) {
    fun install(): Boolean {
        if (!requiredFeatures.all(isSupported)) return false
        return runCatching(closeNetwork).isSuccess
    }

    companion object {
        val requiredFeatures: Set<String> = linkedSetOf(
            WebViewFeature.SERVICE_WORKER_BASIC_USAGE,
            WebViewFeature.SERVICE_WORKER_BLOCK_NETWORK_LOADS,
            WebViewFeature.SERVICE_WORKER_CONTENT_ACCESS,
            WebViewFeature.SERVICE_WORKER_FILE_ACCESS,
        )
    }
}

/** Reverses the Flutter plugin's permissive popup defaults before any load. */
internal class WebPanelWindowPolicy {
    fun install(webView: WebView): Boolean = runCatching {
        webView.settings.javaScriptCanOpenWindowsAutomatically = false
        webView.settings.setSupportMultipleWindows(false)
        !webView.settings.javaScriptCanOpenWindowsAutomatically &&
            !webView.settings.supportMultipleWindows()
    }.getOrDefault(false)
}

internal data class RendererAttachRequest(
    val webViewIdentifier: Long,
    val attachmentId: String,
    val allowedOrigins: Set<WebRequestOrigin>,
    val nativePolicy: WebPanelNativeMessagePolicy?,
) {
    companion object {
        private val idPattern = Regex("^[0-9a-f]{32}$")

        fun parse(arguments: Any?): RendererAttachRequest {
            val values = arguments as? Map<*, *> ?: throw RendererRequestFailure()
            val required = setOf("webViewIdentifier", "attachmentId", "allowedOrigins")
            if (values.keys != required && values.keys != required + "nativePolicy") {
                throw RendererRequestFailure()
            }
            val identifier = when (val value = values["webViewIdentifier"]) {
                is Int -> value.toLong()
                is Long -> value
                else -> throw RendererRequestFailure()
            }
            val attachmentId = values["attachmentId"] as? String
                ?: throw RendererRequestFailure()
            val rawOrigins = values["allowedOrigins"] as? List<*>
                ?: throw RendererRequestFailure()
            if (identifier < 1 ||
                !idPattern.matches(attachmentId) ||
                rawOrigins.isEmpty() ||
                rawOrigins.size > 16
            ) {
                throw RendererRequestFailure()
            }
            val origins = rawOrigins.map(WebRequestOrigin::parse).toSet()
            if (origins.size != rawOrigins.size) throw RendererRequestFailure()
            val nativePolicy = if (values.containsKey("nativePolicy")) {
                WebPanelNativeMessagePolicy.parse(values["nativePolicy"])
            } else {
                null
            }
            if (nativePolicy != null && nativePolicy.origin !in origins) {
                throw RendererRequestFailure()
            }
            return RendererAttachRequest(identifier, attachmentId, origins, nativePolicy)
        }
    }
}

/**
 * Attaches one bounded renderer-gone callback to the plugin-owned WebView.
 * Only opaque instance identifiers and exact allowed-origin descriptors cross
 * the channel. The original plugin client remains the delegate for every
 * navigation and security callback.
 */
class WebPanelRendererBridge(
    messenger: BinaryMessenger,
    private val engine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val serviceWorkerFirewall = ServiceWorkerRequestFirewall()
    private val windowPolicy = WebPanelWindowPolicy()
    private val dynamicEgressPolicy = WebPanelDynamicEgressPolicy()
    private val requestLimiter = WebPanelRequestLimiter.process
    private val attachments = mutableMapOf<String, Attachment>()
    private val viewOwners = mutableMapOf<Long, String>()
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("unavailable", "Renderer monitor unavailable", null)
            return
        }
        try {
            when (call.method) {
                "attach" -> result.success(attach(RendererAttachRequest.parse(call.arguments)))
                "detach" -> result.success(detach(parseDetach(call.arguments)))
                "replyNative" -> result.success(replyNative(call.arguments))
                else -> result.notImplemented()
            }
        } catch (_: RendererRequestFailure) {
            result.error("invalidRequest", "Renderer monitor request rejected", null)
        } catch (_: RuntimeException) {
            result.error("unavailable", "Renderer monitor unavailable", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun attach(request: RendererAttachRequest): Boolean {
        val webView = WebViewFlutterAndroidExternalApi.getWebView(engine, request.webViewIdentifier)
            ?: return false
        if (!serviceWorkerFirewall.install() || !windowPolicy.install(webView)) return false
        viewOwners.remove(request.webViewIdentifier)?.let(::detach)
        attachments.remove(request.attachmentId)?.let { previous ->
            viewOwners.remove(previous.webViewIdentifier, request.attachmentId)
            previous.restore()
        }

        val firewall = WebRequestFirewall(request.allowedOrigins)
        val dynamicEgress = dynamicEgressPolicy.install(webView, request.allowedOrigins)
            ?: return false
        val ownedTransport = runCatching {
            WebPanelOwnedHttpTransport(firewall, requestLimiter = requestLimiter)
        }.getOrElse {
            dynamicEgress.close()
            return false
        }
        val nativeMessages = request.nativePolicy?.let { nativePolicy ->
            WebPanelWebMessageAdapter.install(
                webView,
                request.attachmentId,
                nativePolicy,
            ) { event ->
                channel.invokeMethod(
                    "nativeMessage",
                    mapOf(
                        "attachmentId" to event.attachmentId,
                        "messageId" to event.messageId,
                        "message" to event.message,
                        "topOrigin" to event.topOrigin,
                        "policyRevision" to nativePolicy.revision,
                    ),
                )
            } ?: run {
                ownedTransport.close()
                dynamicEgress.close()
                return false
            }
        }
        val current = webView.webViewClient
        val delegate = if (current is RendererAwareWebViewClient) current.delegate else current
        lateinit var wrapper: RendererAwareWebViewClient
        wrapper = RendererAwareWebViewClient(
            delegate,
            firewall,
            rendererGone = {
                val binding = attachments.remove(request.attachmentId)
                if (binding == null || binding.wrapper !== wrapper) return@RendererAwareWebViewClient
                viewOwners.remove(request.webViewIdentifier, request.attachmentId)
                binding.release(restoreClient = false)
                channel.invokeMethod(
                    "rendererGone",
                    mapOf("attachmentId" to request.attachmentId),
                )
            },
            ownedTransport = ownedTransport,
        )
        try {
            webView.webViewClient = wrapper
        } catch (error: RuntimeException) {
            nativeMessages?.close()
            ownedTransport.close()
            dynamicEgress.close()
            throw error
        }
        attachments[request.attachmentId] = Attachment(
            request.webViewIdentifier,
            webView,
            wrapper,
            dynamicEgress,
            nativeMessages,
        )
        viewOwners[request.webViewIdentifier] = request.attachmentId
        return true
    }

    private fun parseDetach(arguments: Any?): String {
        val values = arguments as? Map<*, *> ?: throw RendererRequestFailure()
        if (values.keys != setOf("attachmentId")) throw RendererRequestFailure()
        val id = values["attachmentId"] as? String ?: throw RendererRequestFailure()
        if (!Regex("^[0-9a-f]{32}$").matches(id)) throw RendererRequestFailure()
        return id
    }

    private fun replyNative(arguments: Any?): Boolean {
        val values = arguments as? Map<*, *> ?: throw RendererRequestFailure()
        if (values.keys != setOf("attachmentId", "messageId", "message")) {
            throw RendererRequestFailure()
        }
        val attachmentId = values["attachmentId"] as? String ?: throw RendererRequestFailure()
        val messageId = when (val value = values["messageId"]) {
            is Int -> value
            is Long -> value.takeIf { it in 1..Int.MAX_VALUE }?.toInt()
            else -> null
        } ?: throw RendererRequestFailure()
        val message = values["message"] as? String ?: throw RendererRequestFailure()
        if (!Regex("^[0-9a-f]{32}$").matches(attachmentId)) throw RendererRequestFailure()
        return attachments[attachmentId]?.nativeMessages?.reply(messageId, message) == true
    }

    private fun detach(attachmentId: String): Boolean {
        val binding = attachments.remove(attachmentId) ?: return false
        viewOwners.remove(binding.webViewIdentifier, attachmentId)
        binding.restore()
        return true
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        attachments.values.toList().forEach(Attachment::restore)
        attachments.clear()
        viewOwners.clear()
        channel.setMethodCallHandler(null)
    }

    private data class Attachment(
        val webViewIdentifier: Long,
        val webView: WebView,
        val wrapper: RendererAwareWebViewClient,
        val dynamicEgress: AutoCloseable,
        val nativeMessages: WebPanelNativeMessageAttachment?,
    ) {
        fun restore() {
            release(restoreClient = true)
        }

        fun release(restoreClient: Boolean) {
            wrapper.retire()
            nativeMessages?.close()
            runCatching(dynamicEgress::close)
            if (restoreClient && webView.webViewClient === wrapper) {
                webView.webViewClient = wrapper.delegate
            }
        }
    }

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/web_panel_renderer"
    }
}

/** Preserves the plugin WebViewClient while owning renderer-gone recovery. */
internal class RendererAwareWebViewClient(
    internal val delegate: WebViewClient,
    private val firewall: WebRequestFirewall,
    private val rendererGone: () -> Unit,
    private val ownedTransport: WebPanelRequestTransport? = null,
    private val rejectClientCertificate: (ClientCertRequest) -> Unit = { it.cancel() },
    private val rejectHttpAuthentication: (HttpAuthHandler) -> Unit = { it.cancel() },
    private val rejectTlsError: (SslErrorHandler) -> Unit = { it.cancel() },
    private val retireRenderer: (WebView) -> Unit = { dead ->
        (dead.parent as? ViewGroup)?.removeView(dead)
        dead.stopLoading()
        dead.destroy()
    },
) : WebViewClient() {
    private val consumed = AtomicBoolean(false)
    private val transportRetired = AtomicBoolean(false)

    fun retire() {
        if (transportRetired.compareAndSet(false, true)) ownedTransport?.close()
    }

    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        if (consumed.compareAndSet(false, true)) {
            retire()
            runCatching { retireRenderer(view) }
            runCatching(rendererGone)
        }
        return true
    }

    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
        if (firewall.allows(request.url)) {
            delegate.shouldOverrideUrlLoading(view, request)
        } else {
            true
        }
    @Suppress("DEPRECATION")
    override fun shouldOverrideUrlLoading(view: WebView, url: String) =
        if (firewall.allows(url)) delegate.shouldOverrideUrlLoading(view, url) else true
    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) =
        delegate.onPageStarted(view, url, favicon)
    override fun onPageFinished(view: WebView, url: String) = delegate.onPageFinished(view, url)
    override fun onLoadResource(view: WebView, url: String) = delegate.onLoadResource(view, url)
    override fun onPageCommitVisible(view: WebView, url: String) =
        delegate.onPageCommitVisible(view, url)
    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
        if (!firewall.allows(request.url)) {
            firewall.blockedResponse()
        } else if (request.isForMainFrame) {
            delegate.shouldInterceptRequest(view, request)
        } else {
            ownedTransport?.fetch(request.url, request.method) ?: firewall.blockedResponse()
        }
    @Suppress("DEPRECATION")
    override fun shouldInterceptRequest(view: WebView, url: String): WebResourceResponse? =
        firewall.blockedResponse()
    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) =
        delegate.onReceivedError(view, request, error)
    @Suppress("DEPRECATION")
    override fun onReceivedError(view: WebView, errorCode: Int, description: String, failingUrl: String) =
        delegate.onReceivedError(view, errorCode, description, failingUrl)
    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        errorResponse: WebResourceResponse,
    ) = delegate.onReceivedHttpError(view, request, errorResponse)
    override fun onFormResubmission(view: WebView, dontResend: Message, resend: Message) =
        delegate.onFormResubmission(view, dontResend, resend)
    @Suppress("DEPRECATION")
    override fun onTooManyRedirects(view: WebView, cancelMsg: Message, continueMsg: Message) =
        delegate.onTooManyRedirects(view, cancelMsg, continueMsg)
    override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) =
        delegate.doUpdateVisitedHistory(view, url, isReload)
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
        runCatching { rejectTlsError(handler) }
    }
    override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) {
        runCatching { rejectClientCertificate(request) }
    }
    override fun onReceivedHttpAuthRequest(
        view: WebView,
        handler: HttpAuthHandler,
        host: String,
        realm: String,
    ) {
        runCatching { rejectHttpAuthentication(handler) }
    }
    override fun shouldOverrideKeyEvent(view: WebView, event: KeyEvent) =
        delegate.shouldOverrideKeyEvent(view, event)
    override fun onUnhandledKeyEvent(view: WebView, event: KeyEvent) =
        delegate.onUnhandledKeyEvent(view, event)
    override fun onScaleChanged(view: WebView, oldScale: Float, newScale: Float) =
        delegate.onScaleChanged(view, oldScale, newScale)
    override fun onReceivedLoginRequest(view: WebView, realm: String, account: String?, args: String) =
        delegate.onReceivedLoginRequest(view, realm, account, args)
    override fun onSafeBrowsingHit(
        view: WebView,
        request: WebResourceRequest,
        threatType: Int,
        callback: SafeBrowsingResponse,
    ) = delegate.onSafeBrowsingHit(view, request, threatType, callback)
}
