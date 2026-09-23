package com.ersingundem.larenor.webpanel

import android.app.Application
import android.graphics.Bitmap
import android.os.Message
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.webkit.WebViewClient
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class WebPanelRendererBridgeTest {
    @Test
    fun exactAttachContractRejectsPrivateOrMalformedArguments() {
        val accepted = RendererAttachRequest.parse(
            mapOf(
                "webViewIdentifier" to 41L,
                "attachmentId" to "0123456789abcdef0123456789abcdef",
            ),
        )
        assertEquals(41L, accepted.webViewIdentifier)

        for (rejected in listOf(
            null,
            emptyMap<String, Any>(),
            mapOf("webViewIdentifier" to 0L, "attachmentId" to "0123456789abcdef0123456789abcdef"),
            mapOf("webViewIdentifier" to 41.5, "attachmentId" to "0123456789abcdef0123456789abcdef"),
            mapOf("webViewIdentifier" to 41L, "attachmentId" to "bad"),
            mapOf(
                "webViewIdentifier" to 41L,
                "attachmentId" to "0123456789abcdef0123456789abcdef",
                "url" to "https://private.invalid/token",
            ),
        )) {
            try {
                RendererAttachRequest.parse(rejected)
                fail("unsafe renderer attachment accepted")
            } catch (_: RendererRequestFailure) {}
        }
    }

    @Test
    fun wrapperPreservesPluginCallbacksAndConsumesRendererGoneOnce() {
        val delegate = RecordingClient()
        var gone = 0
        val wrapper = RendererAwareWebViewClient(delegate) { gone++ }
        val view = WebView(org.robolectric.RuntimeEnvironment.getApplication())

        wrapper.onPageStarted(view, "https://fixture.invalid", null)
        wrapper.onPageFinished(view, "https://fixture.invalid")
        wrapper.onTooManyRedirects(view, Message.obtain(), Message.obtain())
        assertEquals(listOf("start", "finish", "redirect"), delegate.events)

        val detail = object : RenderProcessGoneDetail() {
            override fun didCrash() = true
            override fun rendererPriorityAtExit() = 0
        }
        assertTrue(wrapper.onRenderProcessGone(view, detail))
        assertTrue(wrapper.onRenderProcessGone(view, detail))
        assertEquals(1, gone)
        assertEquals(0, delegate.rendererGone)
    }

    private class RecordingClient : WebViewClient() {
        val events = mutableListOf<String>()
        var rendererGone = 0
        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            events += "start"
        }
        override fun onPageFinished(view: WebView, url: String) {
            events += "finish"
        }
        @Suppress("DEPRECATION")
        override fun onTooManyRedirects(view: WebView, cancelMsg: Message, continueMsg: Message) {
            events += "redirect"
        }
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            rendererGone++
            return false
        }
    }
}
