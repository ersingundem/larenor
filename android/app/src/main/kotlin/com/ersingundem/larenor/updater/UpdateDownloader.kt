package com.ersingundem.larenor.updater

import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.Proxy
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class UpdateCancellation {
    private val cancelled = AtomicBoolean(false)
    @Volatile private var call: Call? = null
    fun attach(value: Call) { call = value; if (cancelled.get()) value.cancel() }
    fun cancel() { cancelled.set(true); call?.cancel() }
    fun check() { if (cancelled.get()) throw UpdateFailure("cancelled") }
    val isCancelled get() = cancelled.get()
}

/** Private staging only. No cookies, redirects, HTTP cache, retries or proxy auth. */
class UpdateDownloader(private val client: OkHttpClient = OkHttpClient.Builder()
    .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
    .proxy(Proxy.NO_PROXY).connectTimeout(20, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS)
    .callTimeout(10, TimeUnit.MINUTES).build()) {
    fun download(baseUrl: String, token: String, release: ClientRelease, destination: File,
                 cancellation: UpdateCancellation, progress: (Long) -> Unit) {
        if (token.isEmpty() || token.length > 8192 || token.any { it.code !in 33..126 }) throw UpdateFailure("invalidMetadata")
        val url = UpdateValidation.url(baseUrl, release)
        cancellation.check()
        val request = Request.Builder().url(url).header("Authorization", "Bearer $token")
            .header("Accept", "application/vnd.android.package-archive").header("Accept-Encoding", "identity").get().build()
        val call = client.newCall(request)
        cancellation.attach(call)
        try {
            call.execute().use { response ->
                cancellation.check()
                if (response.code != 200) throw UpdateFailure(when(response.code) {
                    401 -> "authentication"; 403 -> "permission"; in 300..399 -> "redirect"; else -> "network"
                })
                val body = response.body ?: throw UpdateFailure("network")
                val length = body.contentLength()
                if (length != -1L && length != release.sizeBytes) throw UpdateFailure("verification")
                val digest = MessageDigest.getInstance("SHA-256")
                var received = 0L
                body.byteStream().use { input -> FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        cancellation.check()
                        val count = input.read(buffer)
                        if (count < 0) break
                        received += count
                        if (received > release.sizeBytes || received > ClientRelease.MAX_BYTES) throw UpdateFailure("verification")
                        output.write(buffer, 0, count); digest.update(buffer, 0, count)
                        progress(received)
                    }
                    cancellation.check()
                    output.fd.sync()
                } }
                val hash = digest.digest().joinToString("") { "%02x".format(it) }
                if (received != release.sizeBytes || hash != release.apkSha256) throw UpdateFailure("verification")
            }
        } catch (failure: UpdateFailure) { throw failure }
        catch (_: IOException) { throw UpdateFailure(if (cancellation.isCancelled) "cancelled" else "network") }
        catch (_: Exception) { throw UpdateFailure("unavailable") }
    }
}
