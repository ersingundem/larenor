package com.ersingundem.larenor.webpanel

import android.net.Uri
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.webkit.WebViewFeature
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class WebPanelOwnedTransportTest {
    @Test
    fun ownedTransportFollowsOnlyExactOriginRedirectsWithoutWebViewCredentials() {
        MockWebServer().use { allowed ->
            MockWebServer().use { foreign ->
                val firewall = WebRequestFirewall(
                    setOf(WebRequestOrigin("http", allowed.hostName, allowed.port)),
                )
                val transport = WebPanelOwnedHttpTransport(
                    firewall = firewall,
                    maxResponseBytes = 1024,
                )
                allowed.enqueue(
                    MockResponse().setResponseCode(302).addHeader("Location", "/assets/app.js"),
                )
                allowed.enqueue(
                    MockResponse()
                        .setBody("window.ready = true;")
                        .addHeader("Content-Type", "text/javascript; charset=utf-8"),
                )

                val response = transport.fetch(
                    Uri.parse(allowed.url("/redirect?private=opaque").toString()),
                    "GET",
                )

                assertEquals(200, response.statusCode)
                assertEquals("text/javascript", response.mimeType)
                assertEquals("window.ready = true;", response.data.bufferedReader().use { it.readText() })
                repeat(2) {
                    val request = allowed.takeRequest()
                    assertNull(request.getHeader("Authorization"))
                    assertNull(request.getHeader("Cookie"))
                    assertNull(request.getHeader("Proxy-Authorization"))
                    assertNull(request.getHeader("Referer"))
                }

                allowed.enqueue(
                    MockResponse()
                        .setResponseCode(302)
                        .addHeader("Location", foreign.url("/escaped.js")),
                )
                val blocked = transport.fetch(Uri.parse(allowed.url("/escape").toString()), "GET")
                assertEquals(403, blocked.statusCode)
                assertEquals(-1, blocked.data.read())
                assertNull(foreign.takeRequest(30, TimeUnit.MILLISECONDS))
                transport.close()
            }
        }
    }

    @Test
    fun ownedTransportRejectsBodiesOversizeMethodsAndPostRetirementRequests() {
        MockWebServer().use { server ->
            val firewall = WebRequestFirewall(
                setOf(WebRequestOrigin("http", server.hostName, server.port)),
            )
            val transport = WebPanelOwnedHttpTransport(
                firewall = firewall,
                maxResponseBytes = 8,
            )

            assertEquals(
                403,
                transport.fetch(Uri.parse(server.url("/write").toString()), "POST").statusCode,
            )
            assertEquals(0, server.requestCount)

            server.enqueue(MockResponse().setBody("123456789"))
            assertEquals(
                413,
                transport.fetch(Uri.parse(server.url("/large").toString()), "GET").statusCode,
            )
            assertEquals(1, server.requestCount)

            server.enqueue(MockResponse().setChunkedBody("123456789", 2))
            val streamingOverflow = transport.fetch(
                Uri.parse(server.url("/chunked-large").toString()),
                "GET",
            )
            assertEquals(200, streamingOverflow.statusCode)
            assertThrows(IOException::class.java) { streamingOverflow.data.readBytes() }
            assertEquals(2, server.requestCount)

            transport.close()
            transport.close()
            assertEquals(
                410,
                transport.fetch(Uri.parse(server.url("/retired").toString()), "GET").statusCode,
            )
            assertEquals(2, server.requestCount)
        }
    }

    @Test
    fun retirementCancelsAnInFlightOwnedRequest() {
        MockWebServer().use { server ->
            val transport = WebPanelOwnedHttpTransport(
                firewall = WebRequestFirewall(
                    setOf(WebRequestOrigin("http", server.hostName, server.port)),
                ),
                maxResponseBytes = 8,
                requestLimiter = WebPanelRequestLimiter(1),
            )
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val executor = Executors.newSingleThreadExecutor()
            try {
                val pending = executor.submit<WebResourceResponse> {
                    transport.fetch(Uri.parse(server.url("/pending").toString()), "GET")
                }
                assertNotNull(server.takeRequest(1, TimeUnit.SECONDS))
                assertEquals(
                    429,
                    transport.fetch(
                        Uri.parse(server.url("/over-capacity").toString()),
                        "GET",
                    ).statusCode,
                )
                assertEquals(1, server.requestCount)

                transport.close()

                assertEquals(410, pending.get(1, TimeUnit.SECONDS).statusCode)
            } finally {
                transport.close()
                executor.shutdownNow()
            }
        }
    }

    @Test
    fun sharedLimiterCapsTwoTransportsAndOneDetachDoesNotCancelTheOther() {
        MockWebServer().use { server ->
            repeat(8) { server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)) }
            server.enqueue(MockResponse().setBody("replacement"))
            val origin = WebRequestOrigin("http", server.hostName, server.port)
            val limiter = WebPanelRequestLimiter(8)
            val first = WebPanelOwnedHttpTransport(
                WebRequestFirewall(setOf(origin)),
                requestLimiter = limiter,
            )
            val second = WebPanelOwnedHttpTransport(
                WebRequestFirewall(setOf(origin)),
                requestLimiter = limiter,
            )
            val executor = Executors.newFixedThreadPool(8)
            try {
                val pending = (0 until 8).map { index ->
                    executor.submit<WebResourceResponse> {
                        val transport = if (index < 4) first else second
                        transport.fetch(Uri.parse(server.url("/pending/$index").toString()), "GET")
                    }
                }
                repeat(8) { assertNotNull(server.takeRequest(2, TimeUnit.SECONDS)) }

                assertEquals(
                    429,
                    second.fetch(Uri.parse(server.url("/over-capacity").toString()), "GET")
                        .statusCode,
                )
                assertEquals(8, server.requestCount)

                first.close()
                repeat(4) { assertEquals(410, pending[it].get(1, TimeUnit.SECONDS).statusCode) }
                repeat(4) { assertFalse(pending[it + 4].isDone) }

                val replacement = second.fetch(
                    Uri.parse(server.url("/replacement").toString()),
                    "GET",
                )
                assertEquals("replacement", replacement.data.bufferedReader().use { it.readText() })
                assertEquals(9, server.requestCount)

                second.close()
                repeat(4) { assertEquals(410, pending[it + 4].get(1, TimeUnit.SECONDS).statusCode) }
            } finally {
                first.close()
                second.close()
                executor.shutdownNow()
            }
        }
    }

    @Test
    fun defaultTransportBypassesTheSystemProxyAndPreservesTheExactOriginTarget() {
        MockWebServer().use { origin ->
            MockWebServer().use { proxy ->
                origin.enqueue(MockResponse().setBody("origin"))
                proxy.enqueue(MockResponse().setResponseCode(502))
                val previous = ProxySelector.getDefault()
                ProxySelector.setDefault(object : ProxySelector() {
                    override fun select(uri: URI?) = listOf(
                        Proxy(
                            Proxy.Type.HTTP,
                            InetSocketAddress(proxy.hostName, proxy.port),
                        ),
                    )

                    override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) = Unit
                })
                try {
                    val transport = WebPanelOwnedHttpTransport(
                        WebRequestFirewall(
                            setOf(WebRequestOrigin("http", origin.hostName, origin.port)),
                        ),
                    )
                    val response = transport.fetch(
                        Uri.parse(origin.url("/asset.js?opaque=value").toString()),
                        "GET",
                    )
                    assertEquals("origin", response.data.bufferedReader().use { it.readText() })
                    assertEquals("/asset.js?opaque=value", origin.takeRequest().path)
                    assertNull(proxy.takeRequest(30, TimeUnit.MILLISECONDS))
                    transport.close()
                } finally {
                    ProxySelector.setDefault(previous)
                }
            }
        }
    }

    @Test
    fun bodyFailureSkipOverflowAndAttachmentCloseReturnSharedPermits() {
        MockWebServer().use { server ->
            val origin = WebRequestOrigin("http", server.hostName, server.port)
            val limiter = WebPanelRequestLimiter(1)
            val first = WebPanelOwnedHttpTransport(
                WebRequestFirewall(setOf(origin)),
                maxResponseBytes = 8,
                requestLimiter = limiter,
            )
            val second = WebPanelOwnedHttpTransport(
                WebRequestFirewall(setOf(origin)),
                maxResponseBytes = 8,
                requestLimiter = limiter,
            )
            try {
                server.enqueue(
                    MockResponse()
                        .setBody("12345678")
                        .setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY),
                )
                val disconnected = first.fetch(
                    Uri.parse(server.url("/disconnect").toString()),
                    "GET",
                )
                assertThrows(IOException::class.java) { disconnected.data.readBytes() }

                server.enqueue(MockResponse().setChunkedBody("123456789", 2))
                val skipped = second.fetch(
                    Uri.parse(server.url("/skip-overflow").toString()),
                    "GET",
                )
                assertThrows(IOException::class.java) { skipped.data.skip(9) }

                server.enqueue(MockResponse().setChunkedBody("held", 2))
                val held = first.fetch(
                    Uri.parse(server.url("/held").toString()),
                    "GET",
                )
                assertEquals(200, held.statusCode)
                first.close()

                server.enqueue(MockResponse().setBody("reused"))
                val reused = second.fetch(
                    Uri.parse(server.url("/reused").toString()),
                    "GET",
                )
                assertEquals("reused", reused.data.bufferedReader().use { it.readText() })
            } finally {
                first.close()
                second.close()
            }
        }
    }

    @Test
    fun exactDeclaredLengthReadReturnsSharedPermitWithoutEofOrCallerClose() {
        MockWebServer().use { server ->
            val origin = WebRequestOrigin("http", server.hostName, server.port)
            val limiter = WebPanelRequestLimiter(1)
            val first = WebPanelOwnedHttpTransport(
                WebRequestFirewall(setOf(origin)),
                requestLimiter = limiter,
            )
            val second = WebPanelOwnedHttpTransport(
                WebRequestFirewall(setOf(origin)),
                requestLimiter = limiter,
            )
            try {
                server.enqueue(MockResponse().setBody("asset"))
                server.enqueue(MockResponse().setBody("next"))
                val response = first.fetch(
                    Uri.parse(server.url("/asset.js").toString()),
                    "GET",
                )
                val body = ByteArray(5)
                var offset = 0
                while (offset < body.size) {
                    val read = response.data.read(body, offset, body.size - offset)
                    assertTrue(read > 0)
                    offset += read
                }
                assertEquals("asset", body.decodeToString())

                val next = second.fetch(
                    Uri.parse(server.url("/next.js").toString()),
                    "GET",
                )
                assertEquals(200, next.statusCode)
                assertEquals("next", next.data.bufferedReader().use { it.readText() })
            } finally {
                first.close()
                second.close()
            }
        }
    }

    @Test
    fun documentStartGuardRequiresOfficialFeatureAndSealsDynamicEgress() {
        val view = WebView(org.robolectric.RuntimeEnvironment.getApplication())
        val installed = mutableListOf<Triple<WebView, String, Set<String>>>()
        var removals = 0
        val policy = WebPanelDynamicEgressPolicy(
            isSupported = { it == WebViewFeature.DOCUMENT_START_SCRIPT },
            installScript = { target, script, origins ->
                installed += Triple(target, script, origins)
                AutoCloseable { removals++ }
            },
        )
        val handle = policy.install(
            view,
            linkedSetOf(
                WebRequestOrigin("https", "fixture.invalid", 443),
                WebRequestOrigin("http", "fixture.invalid", 8080),
            ),
        )

        assertNotNull(handle)
        assertEquals(1, installed.size)
        assertSame(view, installed.single().first)
        assertEquals(
            setOf("*"),
            installed.single().third,
        )
        val script = installed.single().second
        assertFalse(script.contains("wss://fixture.invalid:443"))
        assertFalse(script.contains("ws://fixture.invalid:8080"))
        assertTrue(script.contains("WebSocket"))
        assertTrue(script.contains("EventSource"))
        assertTrue(script.contains("WebTransport"))
        assertTrue(script.contains("Worker"))
        assertTrue(script.contains("SharedWorker"))
        assertTrue(script.contains("blockedNetworkContext"))
        assertTrue(script.contains("configurable: false"))
        assertFalse(script.contains("private=opaque"))
        handle!!.close()
        handle.close()
        assertEquals(1, removals)

        var attempted = false
        val unavailable = WebPanelDynamicEgressPolicy(
            isSupported = { false },
            installScript = { _, _, _ ->
                attempted = true
                AutoCloseable {}
            },
        )
        assertNull(
            unavailable.install(
                view,
                setOf(WebRequestOrigin("https", "fixture.invalid", 443)),
            ),
        )
        assertFalse(attempted)
    }
}
