package com.ersingundem.larenor.webpanel

import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Message
import android.view.KeyEvent
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
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.util.concurrent.atomic.AtomicBoolean

internal class RendererRequestFailure : IllegalArgumentException()

internal data class RendererAttachRequest(
    val webViewIdentifier: Long,
    val attachmentId: String,
) {
    companion object {
        private val idPattern = Regex("^[0-9a-f]{32}$")

        fun parse(arguments: Any?): RendererAttachRequest {
            val values = arguments as? Map<*, *> ?: throw RendererRequestFailure()
            if (values.keys != setOf("webViewIdentifier", "attachmentId")) {
                throw RendererRequestFailure()
            }
            val identifier = when (val value = values["webViewIdentifier"]) {
                is Int -> value.toLong()
                is Long -> value
                else -> throw RendererRequestFailure()
            }
            val attachmentId = values["attachmentId"] as? String
                ?: throw RendererRequestFailure()
            if (identifier < 1 || !idPattern.matches(attachmentId)) {
                throw RendererRequestFailure()
            }
            return RendererAttachRequest(identifier, attachmentId)
        }
    }
}

/**
 * Attaches one bounded renderer-gone callback to the plugin-owned WebView.
 * Only opaque instance identifiers cross the channel. The original plugin
 * client remains the delegate for every navigation and security callback.
 */
class WebPanelRendererBridge(
    messenger: BinaryMessenger,
    private val engine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
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
        viewOwners.remove(request.webViewIdentifier)?.let(::detach)
        attachments.remove(request.attachmentId)?.let { previous ->
            viewOwners.remove(previous.webViewIdentifier, request.attachmentId)
            previous.restore()
        }

        val current = webView.webViewClient
        val delegate = if (current is RendererAwareWebViewClient) current.delegate else current
        lateinit var wrapper: RendererAwareWebViewClient
        wrapper = RendererAwareWebViewClient(delegate) {
            val binding = attachments.remove(request.attachmentId)
            if (binding == null || binding.wrapper !== wrapper) return@RendererAwareWebViewClient
            viewOwners.remove(request.webViewIdentifier, request.attachmentId)
            channel.invokeMethod(
                "rendererGone",
                mapOf("attachmentId" to request.attachmentId),
            )
        }
        webView.webViewClient = wrapper
        attachments[request.attachmentId] = Attachment(
            request.webViewIdentifier,
            webView,
            wrapper,
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
    ) {
        fun restore() {
            if (webView.webViewClient === wrapper) webView.webViewClient = wrapper.delegate
        }
    }

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/web_panel_renderer"
    }
}

/** Preserves the plugin WebViewClient while owning renderer-gone recovery. */
internal class RendererAwareWebViewClient(
    internal val delegate: WebViewClient,
    private val rendererGone: () -> Unit,
) : WebViewClient() {
    private val consumed = AtomicBoolean(false)

    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        if (consumed.compareAndSet(false, true)) rendererGone()
        return true
    }

    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
        delegate.shouldOverrideUrlLoading(view, request)
    @Suppress("DEPRECATION")
    override fun shouldOverrideUrlLoading(view: WebView, url: String) =
        delegate.shouldOverrideUrlLoading(view, url)
    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) =
        delegate.onPageStarted(view, url, favicon)
    override fun onPageFinished(view: WebView, url: String) = delegate.onPageFinished(view, url)
    override fun onLoadResource(view: WebView, url: String) = delegate.onLoadResource(view, url)
    override fun onPageCommitVisible(view: WebView, url: String) =
        delegate.onPageCommitVisible(view, url)
    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
        delegate.shouldInterceptRequest(view, request)
    @Suppress("DEPRECATION")
    override fun shouldInterceptRequest(view: WebView, url: String): WebResourceResponse? =
        delegate.shouldInterceptRequest(view, url)
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
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) =
        delegate.onReceivedSslError(view, handler, error)
    override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) =
        delegate.onReceivedClientCertRequest(view, request)
    override fun onReceivedHttpAuthRequest(
        view: WebView,
        handler: HttpAuthHandler,
        host: String,
        realm: String,
    ) = delegate.onReceivedHttpAuthRequest(view, handler, host, realm)
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
