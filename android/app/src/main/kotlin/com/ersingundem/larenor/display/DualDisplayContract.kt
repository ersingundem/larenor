package com.ersingundem.larenor.display

private val SESSION = Regex("display-session-[1-9][0-9]{0,18}-[1-9][0-9]{0,18}-[1-9][0-9]?")
private val PUBLIC_ROUTES = setOf("dashboard.overview", "media.now-playing")

data class DualDisplaySurface(
    val displayId: Int,
    val generation: Long,
    val primary: Boolean,
    val widthPixels: Int,
    val heightPixels: Int,
    val densityDpi: Int,
    val securePresentation: Boolean,
) {
    init {
        require(displayId in 0..63)
        require(generation in 1 until Long.MAX_VALUE)
        require(widthPixels in 320..8192 && heightPixels in 320..8192)
        require(densityDpi in 72..640)
        require(primary == (displayId == 0))
    }

    fun projection() = mapOf(
        "displayId" to displayId,
        "generation" to generation,
        "kind" to if (primary) "primary" else "external",
        "widthPixels" to widthPixels,
        "heightPixels" to heightPixels,
        "densityDpi" to densityDpi,
        "securePresentation" to securePresentation,
    )
}

data class DualDisplayTopology(
    val revision: Long,
    val surfaces: List<DualDisplaySurface>,
) {
    init {
        require(revision in 1 until Long.MAX_VALUE)
        require(surfaces.size in 1..5)
        require(surfaces.count { it.primary } == 1)
        require(surfaces.map { it.displayId }.distinct().size == surfaces.size)
    }

    fun projection() = mapOf(
        "revision" to revision,
        "surfaces" to surfaces.map(DualDisplaySurface::projection),
    )
}

data class DualDisplayRequest(
    val sessionId: String,
    val topologyRevision: Long,
    val displayId: Int,
    val displayGeneration: Long,
    val routeId: String,
) {
    fun receipt(attached: Boolean) = mapOf(
        "sessionId" to sessionId,
        "topologyRevision" to topologyRevision,
        "displayId" to displayId,
        "displayGeneration" to displayGeneration,
        "routeId" to routeId,
        "attached" to attached,
    )

    companion object {
        private val keys = setOf(
            "sessionId",
            "topologyRevision",
            "displayId",
            "displayGeneration",
            "routeId",
        )

        fun parse(raw: Any?): DualDisplayRequest {
            val value = raw.closed(keys)
            val request = DualDisplayRequest(
                sessionId = value.string("sessionId"),
                topologyRevision = value.long("topologyRevision"),
                displayId = value.int("displayId"),
                displayGeneration = value.long("displayGeneration"),
                routeId = value.string("routeId"),
            )
            if (!SESSION.matches(request.sessionId) || request.routeId !in PUBLIC_ROUTES) {
                throw DualDisplayFailure("invalidRequest")
            }
            return request
        }
    }
}

interface DualDisplayHost {
    fun topology(): DualDisplayTopology
    fun present(request: DualDisplayRequest): Boolean
    fun dismiss(displayId: Int)
}

class DualDisplayFailure(val code: String) : RuntimeException(code)

class DualDisplayController(private val host: DualDisplayHost) {
    private var resumed = false
    private var focused = false
    private var active: DualDisplayRequest? = null

    fun snapshot(): Map<String, Any> {
        val topology = host.topology()
        retireIfTopologyChanged(topology)
        return topology.projection()
    }

    fun setResumed(value: Boolean) {
        resumed = value
        if (!value) retire()
    }

    fun setFocused(value: Boolean) {
        focused = value
        if (!value) retire()
    }

    fun present(raw: Any?): Map<String, Any> {
        if (!resumed || !focused) throw DualDisplayFailure("inactive")
        val request = DualDisplayRequest.parse(raw)
        val topology = host.topology()
        retireIfTopologyChanged(topology)
        val surface = topology.surfaces.singleOrNull { it.displayId == request.displayId }
            ?: throw DualDisplayFailure("displayUnavailable")
        if (
            surface.primary ||
            request.topologyRevision != topology.revision ||
            request.displayGeneration != surface.generation
        ) throw DualDisplayFailure("staleTopology")
        val current = active
        if (current != null) {
            if (current == request) return request.receipt(attached = true)
            throw DualDisplayFailure("busy")
        }
        val attached = try {
            host.present(request)
        } catch (_: RuntimeException) {
            false
        }
        if (attached) active = request
        return request.receipt(attached)
    }

    fun dismiss(raw: Any?): Nothing? {
        val value = raw.closed(setOf("sessionId", "displayId"))
        val sessionId = value.string("sessionId")
        val displayId = value.int("displayId")
        if (!SESSION.matches(sessionId) || displayId !in 1..63) {
            throw DualDisplayFailure("invalidRequest")
        }
        val current = active ?: return null
        if (current.sessionId != sessionId || current.displayId != displayId) {
            throw DualDisplayFailure("staleSession")
        }
        retire()
        return null
    }

    fun dispose() {
        resumed = false
        focused = false
        retire()
    }

    private fun retireIfTopologyChanged(topology: DualDisplayTopology) {
        val current = active ?: return
        val surface = topology.surfaces.singleOrNull { it.displayId == current.displayId }
        if (topology.revision != current.topologyRevision ||
            surface?.generation != current.displayGeneration || surface?.primary != false
        ) retire()
    }

    private fun retire() {
        val current = active ?: return
        active = null
        try {
            host.dismiss(current.displayId)
        } catch (_: RuntimeException) {
            // Ownership is retired locally even when the display disappeared.
        }
    }
}

private fun Any?.closed(expected: Set<String>): Map<*, *> {
    val value = this as? Map<*, *> ?: throw DualDisplayFailure("invalidRequest")
    if (value.size != expected.size || value.keys.any { it !is String || it !in expected }) {
        throw DualDisplayFailure("invalidRequest")
    }
    return value
}

private fun Map<*, *>.string(key: String): String =
    this[key] as? String ?: throw DualDisplayFailure("invalidRequest")

private fun Map<*, *>.long(key: String): Long {
    val value = this[key]
    val number = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> throw DualDisplayFailure("invalidRequest")
    }
    if (number !in 1 until Long.MAX_VALUE) throw DualDisplayFailure("invalidRequest")
    return number
}

private fun Map<*, *>.int(key: String): Int {
    val value = this[key]
    val number = when (value) {
        is Int -> value
        is Long -> value.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
        else -> null
    } ?: throw DualDisplayFailure("invalidRequest")
    return number
}
