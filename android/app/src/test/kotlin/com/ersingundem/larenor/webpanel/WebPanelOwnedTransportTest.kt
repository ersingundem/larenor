package com.ersingundem.larenor.webpanel

import android.net.Uri
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.webkit.WebViewFeature
import java.io.IOException
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
            )
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val executor = Executors.newSingleThreadExecutor()
            try {
                val pending = executor.submit<WebResourceResponse> {
                    transport.fetch(Uri.parse(server.url("/pending").toString()), "GET")
                }
                assertNotNull(server.takeRequest(1, TimeUnit.SECONDS))

                transport.close()

                assertEquals(410, pending.get(1, TimeUnit.SECONDS).statusCode)
            } finally {
                transport.close()
                executor.shutdownNow()
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
            setOf("https://fixture.invalid", "http://fixture.invalid:8080"),
            installed.single().third,
        )
        val script = installed.single().second
        assertTrue(script.contains("wss://fixture.invalid:443"))
        assertTrue(script.contains("ws://fixture.invalid:8080"))
        assertTrue(script.contains("WebSocket"))
        assertTrue(script.contains("Worker"))
        assertTrue(script.contains("SharedWorker"))
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
