package com.ersingundem.larenor.music

class CoreMusicSessionRejected(val code: String) :
    RuntimeException("Core music session operation rejected")

data class CoreMusicSessionSnapshot(
    val sessionId: String,
    val playerRevision: Long,
    val title: String,
    val positionMs: Long,
    val durationMs: Long?,
    val isPlaying: Boolean,
    val isGroup: Boolean,
    val canPlay: Boolean,
    val canPause: Boolean,
    val canNext: Boolean,
    val canPrevious: Boolean,
    val canSeek: Boolean,
    val canVolume: Boolean,
    val volumeLevel: Int?,
    val controlsAuthorized: Boolean,
) {
    override fun toString() =
        "CoreMusicSessionSnapshot(revision=$playerRevision, playing=$isPlaying)"

    companion object {
        private val keys = setOf(
            "sessionId", "playerRevision", "title", "positionMs", "durationMs",
            "isPlaying", "isGroup", "canPlay", "canPause", "canNext",
            "canPrevious", "canSeek", "canVolume", "volumeLevel",
            "controlsAuthorized",
        )

        fun parse(value: Any?): CoreMusicSessionSnapshot {
            val map = value as? Map<*, *> ?: throw CoreMusicSessionRejected("invalidState")
            if (map.keys != keys) throw CoreMusicSessionRejected("invalidState")
            val id = text(map["sessionId"], 32)
            if (!Regex("[0-9a-f]{32}").matches(id)) {
                throw CoreMusicSessionRejected("invalidState")
            }
            val revision = integer(map["playerRevision"], 1, Long.MAX_VALUE)
            val title = text(map["title"], 320)
            val position = integer(map["positionMs"], 0, 604_800_000)
            val duration = map["durationMs"]?.let {
                integer(it, position, 604_800_000)
            }
            val volume = map["volumeLevel"]?.let {
                integer(it, 0, 100).toInt()
            }
            val canVolume = boolean(map["canVolume"])
            if (canVolume != (volume != null)) throw CoreMusicSessionRejected("invalidState")
            return CoreMusicSessionSnapshot(
                id, revision, title, position, duration,
                boolean(map["isPlaying"]), boolean(map["isGroup"]),
                boolean(map["canPlay"]), boolean(map["canPause"]),
                boolean(map["canNext"]), boolean(map["canPrevious"]),
                boolean(map["canSeek"]), canVolume, volume,
                boolean(map["controlsAuthorized"]),
            )
        }

        private fun text(value: Any?, limit: Int): String {
            if (value !is String || value.isBlank() || value.length > limit ||
                value.any { it.code < 32 || it.code == 127 }) {
                throw CoreMusicSessionRejected("invalidState")
            }
            return value
        }

        private fun boolean(value: Any?) =
            value as? Boolean ?: throw CoreMusicSessionRejected("invalidState")

        private fun integer(value: Any?, min: Long, max: Long): Long {
            val result = when (value) {
                is Int -> value.toLong()
                is Long -> value
                else -> throw CoreMusicSessionRejected("invalidState")
            }
            if (result !in min..max) throw CoreMusicSessionRejected("invalidState")
            return result
        }
    }
}

data class CoreMusicSessionAction(
    val sessionId: String,
    val playerRevision: Long,
    val action: String,
    val value: Long?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "sessionId" to sessionId,
        "playerRevision" to playerRevision,
        "action" to action,
        "value" to value,
    )

    override fun toString() = "CoreMusicSessionAction($action)"
}

/** Main-thread, single-flight authority boundary between Media3 and Flutter. */
class CoreMusicSessionActionGate {
    private var current: CoreMusicSessionSnapshot? = null
    private var pending = false

    fun publish(value: CoreMusicSessionSnapshot) {
        val old = current
        if (pending && old != null &&
            (old.sessionId != value.sessionId || value.playerRevision <= old.playerRevision)) {
            failClosed()
            throw CoreMusicSessionRejected("stale")
        }
        current = value
        pending = false
    }

    fun begin(sessionId: String, revision: Long, action: String, value: Long?): CoreMusicSessionAction {
        val snapshot = current ?: throw CoreMusicSessionRejected("unavailable")
        if (pending || !snapshot.controlsAuthorized ||
            snapshot.sessionId != sessionId || snapshot.playerRevision != revision) {
            throw CoreMusicSessionRejected(if (pending) "busy" else "stale")
        }
        val supported = when (action) {
            "play" -> snapshot.canPlay && value == null
            "pause" -> snapshot.canPause && value == null
            "next" -> snapshot.canNext && value == null
            "previous" -> snapshot.canPrevious && value == null
            "seek" -> snapshot.canSeek && value != null &&
                value in 0..(snapshot.durationMs ?: -1)
            "volume" -> snapshot.canVolume && value != null && value in 0..100
            else -> false
        }
        if (!supported) throw CoreMusicSessionRejected("unsupported")
        pending = true
        return CoreMusicSessionAction(sessionId, revision, action, value)
    }

    fun complete(value: CoreMusicSessionSnapshot) {
        if (!pending) throw CoreMusicSessionRejected("stale")
        publish(value)
    }

    fun failClosed() {
        pending = false
        current = null
    }

    fun snapshot(): CoreMusicSessionSnapshot? = current
}
