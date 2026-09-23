package com.ersingundem.larenor.webpanel

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Message
import android.webkit.ClientCertRequest
import android.webkit.HttpAuthHandler
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.util.ReflectionHelpers
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
        val ipv6 = RendererAttachRequest.parse(
            attachArguments(
                allowedOrigins = listOf(
                    mapOf("scheme" to "http", "host" to "2001:db8::1", "port" to 8123),
                ),
            ),
        )
        assertEquals(
            setOf(WebRequestOrigin("http", "2001:db8::1", 8123)),
            ipv6.allowedOrigins,
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
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "HTTPS", "host" to "fixture.invalid", "port" to 443))),
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "https", "host" to "FIXTURE.invalid", "port" to 443))),
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "https", "host" to "fixture%2einvalid", "port" to 443))),
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "https", "host" to "fixture\\invalid", "port" to 443))),
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "http", "host" to "[2001:db8::1]", "port" to 8123))),
            attachArguments(allowedOrigins = listOf(mapOf("scheme" to "https", "host" to "-fixture.invalid", "port" to 443))),
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
    fun exactOriginFirewallOwnsSubresourcesWithoutReadingHeadersOrBody() {
        val delegate = RecordingClient()
        val firewall = WebRequestFirewall(
            setOf(
                WebRequestOrigin("https", "fixture.invalid", 443),
                WebRequestOrigin("http", "fixture.invalid", 8080),
            ),
        )
        val transport = RecordingTransport(firewall.blockedResponse())
        val wrapper = RendererAwareWebViewClient(
            delegate,
            firewall,
            rendererGone = {},
            ownedTransport = transport,
        )
        val view = WebView(org.robolectric.RuntimeEnvironment.getApplication())

        assertSame(
            transport.response,
            wrapper.shouldInterceptRequest(view, Request("https://FIXTURE.invalid/asset.js")),
        )
        assertSame(
            transport.response,
            wrapper.shouldInterceptRequest(
                view,
                Request("http://fixture.invalid:8080/api", method = "POST"),
            ),
        )
        assertFalse(
            wrapper.shouldOverrideUrlLoading(
                view,
                Request("https://fixture.invalid/frame", mainFrame = true),
            ),
        )
        assertNull(
            wrapper.shouldInterceptRequest(
                view,
                Request("https://fixture.invalid/main", mainFrame = true),
            ),
        )
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
            assertEquals(
                mapOf(
                    "Cache-Control" to "no-store",
                    "Content-Security-Policy" to "default-src 'none'; sandbox",
                    "Referrer-Policy" to "no-referrer",
                    "X-Content-Type-Options" to "nosniff",
                ),
                blocked.responseHeaders,
            )
            assertTrue(wrapper.shouldOverrideUrlLoading(view, Request(url)))
        }
        assertEquals(1, delegate.intercepted)
        assertEquals(1, delegate.navigations)
        assertEquals(
            listOf(
                "GET https://fixture.invalid/asset.js",
                "POST http://fixture.invalid:8080/api",
            ),
            transport.requests,
        )
        wrapper.retire()
        wrapper.retire()
        assertEquals(1, transport.closes)
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
    fun popupDefaultsAreReversedBeforeThePanelLoads() {
        val view = WebView(org.robolectric.RuntimeEnvironment.getApplication())
        view.settings.javaScriptCanOpenWindowsAutomatically = true
        view.settings.setSupportMultipleWindows(true)

        assertTrue(WebPanelWindowPolicy().install(view))
        assertFalse(view.settings.javaScriptCanOpenWindowsAutomatically)
        assertFalse(view.settings.supportMultipleWindows())
    }

    @Test
    fun credentialAndTlsChallengesFailClosedBeforeThePluginDelegate() {
        val delegate = RecordingClient()
        val clientCertificate = RecordingClientCertRequest()
        var httpAuthRejected = 0
        var tlsRejected = 0
        val wrapper = RendererAwareWebViewClient(
            delegate,
            WebRequestFirewall(setOf(WebRequestOrigin("https", "fixture.invalid", 443))),
            rendererGone = {},
            rejectClientCertificate = { it.cancel() },
            rejectHttpAuthentication = { httpAuthRejected++ },
            rejectTlsError = { tlsRejected++ },
        )
        val view = WebView(org.robolectric.RuntimeEnvironment.getApplication())

        wrapper.onReceivedClientCertRequest(view, clientCertificate)
        wrapper.onReceivedHttpAuthRequest(
            view,
            ReflectionHelpers.newInstance(HttpAuthHandler::class.java),
            "private.invalid",
            "private",
        )
        wrapper.onReceivedSslError(
            view,
            ReflectionHelpers.newInstance(SslErrorHandler::class.java),
            ReflectionHelpers.newInstance(SslError::class.java),
        )

        assertTrue(clientCertificate.cancelled)
        assertEquals(1, httpAuthRejected)
        assertEquals(1, tlsRejected)
        assertEquals(0, delegate.securityChallenges)
    }

    @Test
    fun wrapperPreservesPluginCallbacksAndConsumesRendererGoneOnce() {
        val delegate = RecordingClient()
        var gone = 0
        val wrapper = RendererAwareWebViewClient(
            delegate,
            WebRequestFirewall(setOf(WebRequestOrigin("https", "fixture.invalid", 443))),
            rendererGone = { gone++ },
        )
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

    @Test
    fun rendererGoneContainsLocalCallbackFailureAndStillConsumesTheEvent() {
        var attempts = 0
        var retirements = 0
        val wrapper = RendererAwareWebViewClient(
            RecordingClient(),
            WebRequestFirewall(setOf(WebRequestOrigin("https", "fixture.invalid", 443))),
            rendererGone = {
                attempts++
                error("private callback failure")
            },
            retireRenderer = { retirements++ },
        )
        val view = WebView(org.robolectric.RuntimeEnvironment.getApplication())
        val detail = object : RenderProcessGoneDetail() {
            override fun didCrash() = true
            override fun rendererPriorityAtExit() = 0
        }

        assertTrue(wrapper.onRenderProcessGone(view, detail))
        assertTrue(wrapper.onRenderProcessGone(view, detail))
        assertEquals(1, attempts)
        assertEquals(1, retirements)
    }

    @Test
    fun rendererRetirementFailureCannotSuppressRecoveryOrReplayCleanup() {
        var callbacks = 0
        var retirements = 0
        val wrapper = RendererAwareWebViewClient(
            RecordingClient(),
            WebRequestFirewall(setOf(WebRequestOrigin("https", "fixture.invalid", 443))),
            rendererGone = { callbacks++ },
            retireRenderer = {
                retirements++
                error("private destroy failure")
            },
        )
        val view = WebView(org.robolectric.RuntimeEnvironment.getApplication())
        val detail = object : RenderProcessGoneDetail() {
            override fun didCrash() = true
            override fun rendererPriorityAtExit() = 0
        }

        assertTrue(wrapper.onRenderProcessGone(view, detail))
        assertTrue(wrapper.onRenderProcessGone(view, detail))
        assertEquals(1, retirements)
        assertEquals(1, callbacks)
    }

    private class RecordingClient : WebViewClient() {
        val events = mutableListOf<String>()
        var rendererGone = 0
        var intercepted = 0
        var navigations = 0
        var securityChallenges = 0
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
        override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) {
            securityChallenges++
        }
        override fun onReceivedHttpAuthRequest(
            view: WebView,
            handler: HttpAuthHandler,
            host: String,
            realm: String,
        ) {
            securityChallenges++
        }
        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            securityChallenges++
        }
    }

    private class RecordingClientCertRequest : ClientCertRequest() {
        var cancelled = false
        override fun getKeyTypes() = emptyArray<String>()
        override fun getPrincipals() = emptyArray<Principal>()
        override fun getHost() = "private.invalid"
        override fun getPort() = 443
        override fun proceed(privateKey: PrivateKey, chain: Array<out X509Certificate>) = Unit
        override fun ignore() = Unit
        override fun cancel() {
            cancelled = true
        }
    }

    private class Request(
        rawUrl: String,
        private val method: String = "GET",
        private val mainFrame: Boolean = false,
    ) : WebResourceRequest {
        private val uri = Uri.parse(rawUrl)
        override fun getUrl() = uri
        override fun isForMainFrame() = mainFrame
        override fun isRedirect() = false
        override fun hasGesture() = false
        override fun getMethod() = method
        override fun getRequestHeaders(): MutableMap<String, String> =
            throw AssertionError("firewall must not read request headers")
    }

    private class RecordingTransport(
        val response: WebResourceResponse,
    ) : WebPanelRequestTransport {
        val requests = mutableListOf<String>()
        var closes = 0

        override fun fetch(uri: Uri, method: String): WebResourceResponse {
            val port = if (uri.port >= 0) ":${uri.port}" else ""
            requests += "$method ${uri.scheme}://${uri.host}$port${uri.path}"
            return response
        }

        override fun close() {
            closes++
        }
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
