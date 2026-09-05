package com.ersingundem.larenor.audio

import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Isolated anonymous transport. No app credentials, cookies, redirects, or
 * disk cache. A station requiring those features needs a separate resolver. */
object SafeAudioHttp {
    fun client(): OkHttpClient = OkHttpClient.Builder()
        .cookieJar(CookieJar.NO_COOKIES)
        .authenticator(Authenticator.NONE)
        .proxyAuthenticator(Authenticator.NONE)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val request = chain.request()
            try { AudioSource.safeUri(request.url.toString()) } catch (_: AudioRejected) {
                throw IOException("Audio source rejected")
            }
            if (request.method != "GET" || request.header("Authorization") != null ||
                request.header("Cookie") != null || request.header("Proxy-Authorization") != null) {
                throw IOException("Audio source rejected")
            }
            chain.proceed(request)
        }.build()
}
