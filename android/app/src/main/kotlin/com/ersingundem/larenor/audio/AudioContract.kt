package com.ersingundem.larenor.audio

import java.net.URI
import java.util.UUID

/** Never include parser/player exceptions or source URLs in channel errors. */
class AudioRejected(val code: String) : RuntimeException("Local audio operation rejected")

class AudioSource private constructor(
    val id: String,
    val uri: URI,
    val mimeType: String,
    val title: String,
    val artist: String?,
    val album: String?,
    val artworkBytes: ByteArray?,
) {
    override fun toString() = "AudioSource(redacted)"
    companion object {
        val mimeTypes = setOf("audio/mpeg", "audio/aac", "audio/mp4", "audio/ogg", "audio/flac", "audio/wav")
        private val keys = setOf("id", "uri", "mimeType", "title", "artist", "album", "artworkBytes")
        fun parse(value: Any?): AudioSource {
            val map = value as? Map<*, *> ?: throw AudioRejected("invalidSource")
            if (map.keys.any { it !in keys }) throw AudioRejected("invalidSource")
            val id = text(map["id"], 128) ?: throw AudioRejected("invalidSource")
            if (!Regex("[a-zA-Z0-9_-]{1,128}").matches(id)) throw AudioRejected("invalidSource")
            val mime = text(map["mimeType"], 32)
            if (mime !in mimeTypes) throw AudioRejected("invalidSource")
            return AudioSource(id, safeUri(map["uri"]), mime!!,
                text(map["title"], 256) ?: throw AudioRejected("invalidSource"),
                text(map["artist"], 256), text(map["album"], 256),
                map["artworkBytes"]?.let { AudioArtwork.input(it, AudioArtwork.MAX_OUTPUT_BYTES) })
        }

        fun text(value: Any?, limit: Int): String? {
            if (value == null) return null
            if (value !is String || value.isBlank() || value.length > limit ||
                value.any { it.code < 32 || it.code == 127 }) throw AudioRejected("invalidSource")
            return value
        }

        fun safeUri(value: Any?): URI {
            if (value !is String || value.length !in 1..2048 ||
                value.any { it.code <= 32 || it.code == 127 } || value.contains('\\')) {
                throw AudioRejected("invalidSource")
            }
            val uri = try { URI(value) } catch (_: Exception) { throw AudioRejected("invalidSource") }
            if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank() ||
                uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null ||
                uri.port == 0 || uri.port < -1 || uri.port > 65535 ||
                Regex("%0[0-9a-f]|%1[0-9a-f]|%7f", RegexOption.IGNORE_CASE).containsMatchIn(uri.rawPath.orEmpty())) {
                throw AudioRejected("invalidSource")
            }
            return uri
        }

        fun sameOrigin(a: URI, b: URI): Boolean = a.scheme == b.scheme &&
            a.host.equals(b.host, ignoreCase = true) && port(a) == port(b)
        private fun port(uri: URI) = if (uri.port != -1) uri.port else if (uri.scheme == "https") 443 else 80
    }
}

data class AudioSnapshot(
    val phase: String = "idle",
    val sourceId: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    val isPlaying: Boolean = false,
    val positionMs: Long? = null,
    val durationMs: Long? = null,
    val canPlay: Boolean = false,
    val canPause: Boolean = false,
    val canSeek: Boolean = false,
    val canStop: Boolean = false,
    val failure: String? = null,
    val artworkState: String = "none",
    val artworkId: String? = null,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "supported" to true, "phase" to phase, "sourceId" to sourceId,
        "title" to title, "artist" to artist, "album" to album,
        "isPlaying" to isPlaying, "positionMs" to positionMs, "durationMs" to durationMs,
        "canPlay" to canPlay, "canPause" to canPause, "canSeek" to canSeek,
        "canStop" to canStop, "failure" to failure,
        "artworkState" to artworkState, "artworkId" to artworkId,
    )
}

interface AudioOwner {
    fun pause()
    fun resume()
    fun seek(positionMs: Long)
    fun shutdown()
    fun snapshot(): AudioSnapshot
    fun artwork(sourceId: String, artworkId: String): Map<String, Any> = throw AudioRejected("unavailable")
}

/** Main-thread owner and single-use launch gate. No URLs are stored in Android
 * intents, preferences, media IDs, notification extras, or public snapshots. */
class AudioCoordinator(private val nowMs: () -> Long) {
    private data class Pending(val ticket: String, val source: AudioSource, val deadline: Long)
    private var pending: Pending? = null
    private var owner: AudioOwner? = null
    private val observers = linkedSetOf<(AudioSnapshot) -> Unit>()
    var state = AudioSnapshot()
        private set
    val hasPending get() = pending != null
    val hasOwner get() = owner != null
    val hasObservers get() = observers.isNotEmpty()

    fun request(source: AudioSource, foreground: Boolean): String {
        if (!foreground) throw AudioRejected("foregroundRequired")
        if (pending != null) throw AudioRejected("busy")
        val ticket = UUID.randomUUID().toString()
        pending = Pending(ticket, source, nowMs() + 5000)
        publish(AudioSnapshot(phase = "loading", sourceId = source.id, title = source.title,
            artist = source.artist, album = source.album, canStop = true))
        return ticket
    }

    fun consume(ticket: String?, foreground: Boolean): AudioSource? {
        val value = pending ?: return null
        if (ticket != value.ticket) return null
        pending = null
        if (!foreground || nowMs() >= value.deadline) {
            publish(owner?.snapshot() ?: AudioSnapshot(failure = "foregroundRequired"))
            return null
        }
        return value.source
    }

    fun cancelPending() {
        if (pending == null) return
        pending = null
        publish(owner?.snapshot() ?: AudioSnapshot())
    }

    fun attach(value: AudioOwner) {
        if (owner != null && owner !== value) throw AudioRejected("busy")
        owner = value
    }

    fun report(value: AudioOwner, snapshot: AudioSnapshot) {
        if (owner === value && pending == null) publish(snapshot)
    }

    fun detach(value: AudioOwner) {
        if (owner !== value) return
        owner = null
        // Preserve an explicitly reported failure but no active-session claim.
        if (state.phase != "error" && pending == null) publish(AudioSnapshot())
    }

    fun stop() {
        pending = null
        val previous = owner
        owner = null
        previous?.shutdown()
        publish(AudioSnapshot())
    }

    fun refreshSnapshot() {
        if (pending == null) owner?.let { publish(it.snapshot()) }
    }

    fun artwork(sourceId: String, artworkId: String): Map<String, Any> {
        requireSource(sourceId)
        if (state.artworkId != artworkId || state.artworkState != "ready") throw AudioRejected("unavailable")
        return owner?.artwork(sourceId, artworkId) ?: throw AudioRejected("unavailable")
    }

    fun requireSource(expected: String?) {
        if (expected != null && (state.sourceId != expected || pending != null)) {
            throw AudioRejected("unavailable")
        }
    }

    fun pause() {
        if (!state.canPause) throw AudioRejected("unavailable")
        owner?.pause() ?: throw AudioRejected("unavailable")
    }

    fun resume(foreground: Boolean) {
        if (!foreground) throw AudioRejected("foregroundRequired")
        if (!state.canPlay) throw AudioRejected("unavailable")
        owner?.resume() ?: throw AudioRejected("unavailable")
    }

    fun seek(value: Any?) {
        if (value !is Long && value !is Int) throw AudioRejected("invalidPosition")
        val position = (value as Number).toLong()
        val duration = state.durationMs
        if (!state.canSeek || duration == null || position < 0 || position > duration) {
            throw AudioRejected("invalidPosition")
        }
        owner?.seek(position) ?: throw AudioRejected("unavailable")
    }

    fun observe(listener: (AudioSnapshot) -> Unit): () -> Unit {
        observers.add(listener)
        listener(state)
        return { observers.remove(listener) }
    }

    private fun publish(value: AudioSnapshot) {
        state = value
        observers.toList().forEach { it(value) }
    }
}

object AudioControllerPolicy {
    fun mayConnect(ownUid: Boolean, trusted: Boolean, notificationController: Boolean) =
        ownUid || trusted || notificationController
}

interface AudioCommandHost {
    val foreground: Boolean
    val coordinator: AudioCoordinator
    fun start(ticket: String)
    fun powerStatus(): Map<String, Any?>
    fun openSettings(notification: Boolean): Boolean
}

/** Shared by the real MethodChannel handler and JVM contract tests. */
class AudioCommandRouter(private val host: AudioCommandHost) {
    fun call(method: String, arguments: Any?): Any? = when (method) {
        "snapshot" -> { host.coordinator.refreshSnapshot(); host.coordinator.state.toMap() }
        "artwork" -> {
            if (!host.foreground) throw AudioRejected("foregroundRequired")
            val map = arguments as? Map<*, *> ?: throw AudioRejected("invalidArtwork")
            val source = map["sourceId"] as? String ?: throw AudioRejected("invalidArtwork")
            val artwork = map["artworkId"] as? String ?: throw AudioRejected("invalidArtwork")
            if (map.keys != setOf("sourceId", "artworkId") ||
                !Regex("[a-zA-Z0-9_-]{1,128}").matches(source) ||
                !Regex("[a-zA-Z0-9_-]{1,128}").matches(artwork)) throw AudioRejected("invalidArtwork")
            host.coordinator.artwork(source, artwork)
        }
        "play" -> {
            val source = AudioSource.parse(arguments)
            val ticket = host.coordinator.request(source, host.foreground)
            try { host.start(ticket) } catch (_: Exception) {
                host.coordinator.cancelPending()
                throw AudioRejected("unavailable")
            }
            null
        }
        "pause" -> { checkSource(arguments); host.coordinator.pause(); null }
        "resume" -> { checkSource(arguments); host.coordinator.resume(host.foreground); null }
        "seek" -> {
            if (arguments is Map<*, *>) {
                checkSource(arguments, seek = true)
                host.coordinator.seek(arguments["positionMs"])
            } else host.coordinator.seek(arguments)
            null
        }
        "stop" -> { checkSource(arguments); host.coordinator.stop(); null }
        "powerStatus" -> { noArguments(arguments); host.powerStatus() }
        "openBatterySettings", "openNotificationSettings" -> {
            noArguments(arguments)
            if (!host.foreground) throw AudioRejected("foregroundRequired")
            host.openSettings(method == "openNotificationSettings")
        }
        else -> throw AudioRejected("unsupported")
    }
    private fun noArguments(value: Any?) {
        if (value != null) throw AudioRejected("invalidSource")
    }
    private fun checkSource(value: Any?, seek: Boolean = false) {
        if (value == null && !seek) return
        val map = value as? Map<*, *> ?: throw AudioRejected("invalidSource")
        val expected = map["sourceId"]
        val keys = if (seek) setOf("sourceId", "positionMs") else setOf("sourceId")
        if (map.keys != keys || expected !is String || !Regex("[a-zA-Z0-9_-]{1,128}").matches(expected)) {
            throw AudioRejected("invalidSource")
        }
        // This and the owner command run in one main-thread MethodChannel call.
        host.coordinator.requireSource(expected)
    }
}
