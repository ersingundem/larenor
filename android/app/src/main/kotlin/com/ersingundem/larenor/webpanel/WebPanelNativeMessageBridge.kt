package com.ersingundem.larenor.webpanel

import android.net.Uri
import android.webkit.WebView
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.util.concurrent.atomic.AtomicBoolean

internal data class WebPanelNativeMessagePolicy(
    val revision: Int,
    val topOrigin: String,
    val methods: Set<String>,
    val origin: WebRequestOrigin,
) {
    companion object {
        private val methods = setOf("speak", "printDocument", "scanQr")

        fun parse(value: Any?): WebPanelNativeMessagePolicy {
            val raw = value as? Map<*, *> ?: throw RendererRequestFailure()
            if (raw.keys != setOf("schemaVersion", "revision", "topOrigin", "methods") ||
                raw["schemaVersion"] != 1
            ) {
                throw RendererRequestFailure()
            }
            val revision = when (val value = raw["revision"]) {
                is Int -> value
                is Long -> value.takeIf { it in 1..Int.MAX_VALUE }?.toInt()
                else -> null
            } ?: throw RendererRequestFailure()
            val topOrigin = raw["topOrigin"] as? String ?: throw RendererRequestFailure()
            val rawMethods = raw["methods"] as? List<*> ?: throw RendererRequestFailure()
            if (revision !in 1..Int.MAX_VALUE || rawMethods.isEmpty() || rawMethods.size > methods.size) {
                throw RendererRequestFailure()
            }
            val selected = rawMethods.map {
                it as? String ?: throw RendererRequestFailure()
            }.toSet()
            if (selected.size != rawMethods.size || !methods.containsAll(selected)) {
                throw RendererRequestFailure()
            }
            val uri = Uri.parse(topOrigin)
            if (uri.isOpaque || uri.scheme != "https" || uri.userInfo != null ||
                uri.host == null || (uri.path?.let { it.isNotEmpty() && it != "/" } == true) ||
                uri.query != null || uri.fragment != null
            ) {
                throw RendererRequestFailure()
            }
            val host = uri.host!!.removeSurrounding("[", "]")
            val port = if (uri.port >= 0) uri.port else 443
            val origin = WebRequestOrigin.parse(
                mapOf("scheme" to "https", "host" to host, "port" to port),
            )
            val authorityHost = if (":" in host) "[$host]" else host
            val canonical = "https://$authorityHost" + if (port == 443) "" else ":$port"
            if (topOrigin != canonical) throw RendererRequestFailure()
            return WebPanelNativeMessagePolicy(revision, topOrigin, selected, origin)
        }
    }
}

internal data class WebPanelNativeMessageEvent(
    val attachmentId: String,
    val messageId: Int,
    val message: String,
    val topOrigin: String,
)

internal class WebPanelNativeMessageAttachment(
    private val attachmentId: String,
    internal val policy: WebPanelNativeMessagePolicy,
    private val dispatch: (WebPanelNativeMessageEvent) -> Unit,
    private val removeListener: () -> Unit = {},
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val pending = LinkedHashMap<Int, JavaScriptReplyProxy>()
    private var nextMessageId = 1

    fun onMessage(
        message: String?,
        sourceOrigin: Uri,
        mainFrame: Boolean,
        reply: JavaScriptReplyProxy,
    ) {
        if (closed.get() || !mainFrame || message == null ||
            message.toByteArray(Charsets.UTF_8).size > MAX_MESSAGE_BYTES ||
            !policy.origin.matches(sourceOrigin) || pending.size >= MAX_PENDING_REPLIES
        ) {
            return
        }
        val messageId = nextMessageId++
        pending[messageId] = reply
        try {
            dispatch(
                WebPanelNativeMessageEvent(
                    attachmentId = attachmentId,
                    messageId = messageId,
                    message = message,
                    topOrigin = policy.topOrigin,
                ),
            )
        } catch (_: RuntimeException) {
            pending.remove(messageId)
        }
    }

    fun reply(messageId: Int, message: String): Boolean {
        if (closed.get() || messageId < 1 ||
            message.toByteArray(Charsets.UTF_8).size > MAX_MESSAGE_BYTES
        ) {
            return false
        }
        val target = pending.remove(messageId) ?: return false
        return runCatching { target.postMessage(message) }.isSuccess
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        pending.clear()
        runCatching(removeListener)
    }

    companion object {
        private const val MAX_MESSAGE_BYTES = 8 * 1024
        private const val MAX_PENDING_REPLIES = 128
    }
}

internal object WebPanelWebMessageAdapter {
    private const val OBJECT_NAME = "larenorNative"

    fun install(
        webView: WebView,
        attachmentId: String,
        policy: WebPanelNativeMessagePolicy,
        dispatch: (WebPanelNativeMessageEvent) -> Unit,
    ): WebPanelNativeMessageAttachment? {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) return null
        lateinit var attachment: WebPanelNativeMessageAttachment
        attachment = WebPanelNativeMessageAttachment(
            attachmentId = attachmentId,
            policy = policy,
            dispatch = dispatch,
            removeListener = { WebViewCompat.removeWebMessageListener(webView, OBJECT_NAME) },
        )
        return try {
            WebViewCompat.addWebMessageListener(
                webView,
                OBJECT_NAME,
                setOf(policy.topOrigin),
            ) { _, message, sourceOrigin, isMainFrame, reply ->
                attachment.onMessage(message.data, sourceOrigin, isMainFrame, reply)
            }
            attachment
        } catch (_: RuntimeException) {
            attachment.close()
            null
        }
    }
}
