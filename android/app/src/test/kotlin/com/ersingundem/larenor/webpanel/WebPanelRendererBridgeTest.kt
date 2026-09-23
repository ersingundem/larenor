package com.ersingundem.larenor.webpanel

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import android.os.Message
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
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
                "allowedOrigins" to listOf(
                    mapOf("scheme" to "https", "host" to "fixture.invalid", "port" to 443),
                    mapOf("scheme" to "http", "host" to "fixture.invalid", "port" to 8080),
                ),
            ),
        )
        assertEquals(41L, accepted.webViewIdentifier)
        assertEquals(
            setOf(
                WebRequestOrigin("https", "fixture.invalid", 443),
                WebRequestOrigin("http", "fixture.invalid", 8080),
            ),
            accepted.allowedOrigins,
        )

        for (rejected in listOf(
            null,
            emptyMap<String, Any>(),
            attachArguments(webViewIdentifier = 0L),
            attachArguments(webViewIdentifier = 41.5),
            attachArguments(attachmentId = "bad"),
            attachArguments(allowedOrigins = emptyList()),
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "file", "host" to "fixture.invalid", "port" to 443))),
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "https", "host" to "", "port" to 443))),
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "https", "host" to "fixture.invalid", "port" to 0))),
            attachArguments(allowedOrigins = List(2) { mapOf("scheme" to "https", "host" to "fixture.invalid", "port" to 443) }),
            attachArguments(allowedOrigins = List(17) { mapOf("scheme" to "https", "host" to "$it.invalid", "port" to 443) }),
            mapOf(
                "webViewIdentifier" to 41L,
                "attachmentId" to "0123456789abcdef0123456789abcdef",
                "allowedOrigins" to listOf(mapOf("scheme" to "https", "host" to "fixture.invalid", "port" to 443)),
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
    fun exactOriginFirewallRejectsBeforeDelegateWithoutReadingHeadersOrBody() {
        val delegate = RecordingClient()
        val firewall = WebRequestFirewall(
            setOf(
                WebRequestOrigin("https", "fixture.invalid", 443),
                WebRequestOrigin("http", "fixture.invalid", 8080),
            ),
        )
        val wrapper = RendererAwareWebViewClient(delegate, firewall) {}
        val view = WebView(org.robolectric.RuntimeEnvironment.getApplication())

        assertNull(wrapper.shouldInterceptRequest(view, Request("https://FIXTURE.invalid/asset.js")))
        assertNull(wrapper.shouldInterceptRequest(view, Request("http://fixture.invalid:8080/api", method = "POST")))
        assertFalse(wrapper.shouldOverrideUrlLoading(view, Request("https://fixture.invalid/frame")))
        for (url in listOf(
            "http://fixture.invalid/asset.js",
            "https://fixture.invalid:444/asset.js",
            "https://sub.fixture.invalid/asset.js",
            "file:///private/data",
            "data:text/plain,private",
        )) {
            val blocked = wrapper.shouldInterceptRequest(view, Request(url))
            assertNotNull(url, blocked)
            assertEquals(403, blocked!!.statusCode)
            assertEquals(-1, blocked.data.read())
            assertTrue(wrapper.shouldOverrideUrlLoading(view, Request(url)))
        }
        assertEquals(2, delegate.intercepted)
        assertEquals(1, delegate.navigations)
    }

    @Test
    fun serviceWorkerBoundaryRequiresEveryClosedFeatureAndFailsOnMutationError() {
        val checked = mutableSetOf<String>()
        var closures = 0
        val supported = ServiceWorkerRequestFirewall(
            isSupported = { feature -> checked += feature; true },
            closeNetwork = { closures++ },
        )
        assertTrue(supported.install())
        assertEquals(ServiceWorkerRequestFirewall.requiredFeatures, checked)
        assertEquals(1, closures)

        val unavailable = ServiceWorkerRequestFirewall(
            isSupported = { feature -> feature != ServiceWorkerRequestFirewall.requiredFeatures.first() },
            closeNetwork = { fail("unsupported policy must not mutate settings") },
        )
        assertFalse(unavailable.install())
        assertFalse(ServiceWorkerRequestFirewall(isSupported = { true }, closeNetwork = { error("closed") }).install())
    }

    @Test
    fun wrapperPreservesPluginCallbacksAndConsumesRendererGoneOnce() {
        val delegate = RecordingClient()
        var gone = 0
        val wrapper = RendererAwareWebViewClient(
            delegate,
            WebRequestFirewall(setOf(WebRequestOrigin("https", "fixture.invalid", 443))),
        ) { gone++ }
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
        var intercepted = 0
        var navigations = 0
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
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            intercepted++
            return null
        }
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            navigations++
            return false
        }
    }

    private class Request(
        rawUrl: String,
        private val method: String = "GET",
    ) : WebResourceRequest {
        private val uri = Uri.parse(rawUrl)
        override fun getUrl() = uri
        override fun isForMainFrame() = false
        override fun isRedirect() = false
        override fun hasGesture() = false
        override fun getMethod() = method
        override fun getRequestHeaders(): MutableMap<String, String> =
            throw AssertionError("firewall must not read request headers")
    }

    private fun attachArguments(
        webViewIdentifier: Any = 41L,
        attachmentId: String = "0123456789abcdef0123456789abcdef",
        allowedOrigins: List<Map<String, Any>> = listOf(
            mapOf("scheme" to "https", "host" to "fixture.invalid", "port" to 443),
        ),
    ) = mapOf(
        "webViewIdentifier" to webViewIdentifier,
        "attachmentId" to attachmentId,
        "allowedOrigins" to allowedOrigins,
    )
}
