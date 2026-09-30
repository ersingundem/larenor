package com.ersingundem.larenor.display

private val SESSION = Regex("display-session-[1-9][0-9]{0,18}-[1-9][0-9]{0,18}-[1-9][0-9]?")
private val PUBLIC_ROUTES = setOf("core.status")
private const val MAX_SAFE_INTEGER = 9007199254740991L

data class PublicCoreStatusSnapshot(
    val snapshotRevision: Long,
    val observedAtMs: Long,
    val expiresAtMs: Long,
    val systemLoadPercent: Int,
    val processMemoryMiB: Int,
    val dataDiskFreeBytes: Long,
    val dataDiskTotalBytes: Long,
    val processUptimeSeconds: Long,
) {
    init {
        require(snapshotRevision in 1..MAX_SAFE_INTEGER)
        require(observedAtMs in 0..MAX_SAFE_INTEGER)
        require(expiresAtMs in 1..MAX_SAFE_INTEGER)
        require(expiresAtMs > observedAtMs && expiresAtMs - observedAtMs <= 15_000)
        require(systemLoadPercent in 0..100)
        require(processMemoryMiB in 0..1_048_576)
        require(dataDiskTotalBytes in 1..MAX_SAFE_INTEGER)
        require(dataDiskFreeBytes in 0..dataDiskTotalBytes)
        require(processUptimeSeconds in 0..MAX_SAFE_INTEGER)
    }

    fun projection() = mapOf(
        "schemaVersion" to 1,
        "snapshotRevision" to snapshotRevision,
        "observedAtMs" to observedAtMs,
        "expiresAtMs" to expiresAtMs,
        "serviceState" to "online",
        "apiVersion" to 1,
        "systemLoadPercent" to systemLoadPercent,
        "processMemoryMiB" to processMemoryMiB,
        "dataDiskFreeBytes" to dataDiskFreeBytes,
        "dataDiskTotalBytes" to dataDiskTotalBytes,
        "processUptimeSeconds" to processUptimeSeconds,
    )

    companion object {
        private val keys = setOf(
            "schemaVersion", "snapshotRevision", "observedAtMs", "expiresAtMs",
            "serviceState", "apiVersion", "systemLoadPercent", "processMemoryMiB",
            "dataDiskFreeBytes", "dataDiskTotalBytes", "processUptimeSeconds",
        )

        fun parse(raw: Any?): PublicCoreStatusSnapshot {
            val value = raw.closed(keys)
            if (value.int("schemaVersion") != 1 || value.string("serviceState") != "online" ||
                value.int("apiVersion") != 1) throw DualDisplayFailure("invalidRequest")
            return try {
                PublicCoreStatusSnapshot(
                    snapshotRevision = value.long("snapshotRevision"),
                    observedAtMs = value.nonNegativeLong("observedAtMs"),
                    expiresAtMs = value.long("expiresAtMs"),
                    systemLoadPercent = value.int("systemLoadPercent"),
                    processMemoryMiB = value.int("processMemoryMiB"),
                    dataDiskFreeBytes = value.nonNegativeLong("dataDiskFreeBytes"),
                    dataDiskTotalBytes = value.long("dataDiskTotalBytes"),
                    processUptimeSeconds = value.nonNegativeLong("processUptimeSeconds"),
                )
            } catch (_: IllegalArgumentException) {
                throw DualDisplayFailure("invalidRequest")
            }
        }
    }
}

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
    val publicSnapshot: PublicCoreStatusSnapshot,
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
            "publicSnapshot",
        )

        fun parse(raw: Any?): DualDisplayRequest {
            val value = raw.closed(keys)
            val request = DualDisplayRequest(
                sessionId = value.string("sessionId"),
                topologyRevision = value.long("topologyRevision"),
                displayId = value.int("displayId"),
                displayGeneration = value.long("displayGeneration"),
                routeId = value.string("routeId"),
                publicSnapshot = PublicCoreStatusSnapshot.parse(value["publicSnapshot"]),
            )
            if (!SESSION.matches(request.sessionId) || request.routeId !in PUBLIC_ROUTES) {
                throw DualDisplayFailure("invalidRequest")
            }
            return request
        }
    }
}

data class DualDisplayPublicUpdate(
    val sessionId: String,
    val displayId: Int,
    val publicSnapshot: PublicCoreStatusSnapshot,
) {
    companion object {
        fun parse(raw: Any?): DualDisplayPublicUpdate {
            val value = raw.closed(setOf("sessionId", "displayId", "publicSnapshot"))
            val update = DualDisplayPublicUpdate(
                value.string("sessionId"),
                value.int("displayId"),
                PublicCoreStatusSnapshot.parse(value["publicSnapshot"]),
            )
            if (!SESSION.matches(update.sessionId) || update.displayId !in 1..63) {
                throw DualDisplayFailure("invalidRequest")
            }
            return update
        }
    }
}

interface DualDisplayHost {
    fun topology(): DualDisplayTopology
    fun present(request: DualDisplayRequest): Boolean
    fun dismiss(displayId: Int)
    fun publish(update: DualDisplayPublicUpdate, completion: (Boolean) -> Unit) = completion(false)
}

class DualDisplayFailure(val code: String) : RuntimeException(code)

class DualDisplayController(private val host: DualDisplayHost) {
    private var resumed = false
    private var focused = false
    private var active: DualDisplayRequest? = null
    private var latestSnapshotRevision = 0L

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
        if (attached) latestSnapshotRevision = request.publicSnapshot.snapshotRevision
        return request.receipt(attached)
    }

    fun publish(raw: Any?, completion: (Boolean) -> Unit) {
        if (!resumed || !focused) throw DualDisplayFailure("inactive")
        val update = DualDisplayPublicUpdate.parse(raw)
        val current = active ?: throw DualDisplayFailure("staleSession")
        if (current.sessionId != update.sessionId || current.displayId != update.displayId) {
            throw DualDisplayFailure("staleSession")
        }
        if (update.publicSnapshot.snapshotRevision < latestSnapshotRevision) {
            throw DualDisplayFailure("staleSnapshot")
        }
        if (update.publicSnapshot.snapshotRevision == latestSnapshotRevision) {
            completion(true)
            return
        }
        host.publish(update) { accepted ->
            val stillCurrent = active
            if (accepted && stillCurrent === current) {
                latestSnapshotRevision = update.publicSnapshot.snapshotRevision
                completion(true)
            } else {
                completion(false)
            }
        }
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
        latestSnapshotRevision = 0
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

private fun Map<*, *>.nonNegativeLong(key: String): Long {
    val value = this[key]
    val number = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> throw DualDisplayFailure("invalidRequest")
    }
    if (number !in 0..MAX_SAFE_INTEGER) throw DualDisplayFailure("invalidRequest")
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
