package com.ersingundem.larenor.audio

import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.TimeUnit

class SafeAudioHttpTest {
    @Test fun anonymousReadsDoNotRetainCookiesOrFollowCredentialRedirects() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("audio").addHeader("Set-Cookie", "session=secret"))
            server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "/private?token=secret"))
            val client = SafeAudioHttp.client()
            client.newCall(Request.Builder().url(server.url("/one.mp3")).build()).execute().close()
            client.newCall(Request.Builder().url(server.url("/two.mp3")).build()).execute().use {
                assertEquals(302, it.code)
            }
            assertNull(server.takeRequest().getHeader("Cookie"))
            val second = server.takeRequest()
            assertNull(second.getHeader("Cookie"))
            assertNull(second.getHeader("Authorization"))
            assertNull(server.takeRequest(30, TimeUnit.MILLISECONDS))
            client.connectionPool.evictAll()
        }
    }
    @Test fun unsafeHeaderQueryAndMethodsAreRejectedBeforeNetwork() {
        MockWebServer().use { server ->
            val client = SafeAudioHttp.client()
            val requests = listOf(
                Request.Builder().url(server.url("/audio?api_key=secret")).build(),
                Request.Builder().url(server.url("/audio")).header("Authorization", "Bearer secret").build(),
                Request.Builder().url(server.url("/audio")).header("Cookie", "session=secret").build(),
                Request.Builder().url(server.url("/audio")).head().build(),
            )
            requests.forEach { request ->
                try { client.newCall(request).execute(); fail("Expected rejection") } catch (error: IOException) {
                    assertFalse(error.toString().contains("secret"))
                }
            }
            assertEquals(0, server.requestCount)
            client.connectionPool.evictAll()
        }
    }
}
