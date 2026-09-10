package com.ersingundem.larenor.cast

class CoreCastRouteRejected(val code: String) :
    RuntimeException("Google Cast route state rejected")

data class CoreCastRoute(
    val id: String,
    val name: String,
    val kind: String,
    val available: Boolean,
    val connectionState: String,
    val volumeLevel: Int?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "name" to name,
        "kind" to kind,
        "available" to available,
        "connectionState" to connectionState,
        "volumeLevel" to volumeLevel,
    )

    companion object {
        private val keys = setOf(
            "id", "name", "kind", "available", "connectionState", "volumeLevel",
        )
        private val idPattern = Regex(
            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        )

        fun parse(value: Any?): CoreCastRoute {
            val map = value as? Map<*, *> ?: invalid()
            if (map.keys != keys) invalid()
            val id = map["id"] as? String ?: invalid()
            val name = map["name"] as? String ?: invalid()
            val kind = map["kind"] as? String ?: invalid()
            val available = map["available"] as? Boolean ?: invalid()
            val connectionState = map["connectionState"] as? String ?: invalid()
            val volumeLevel = map["volumeLevel"]?.let(::integer)
            if (!idPattern.matches(id) ||
                name.isBlank() || name.length > 160 ||
                name.any { it.code < 32 || it.code == 127 } ||
                kind !in setOf("device", "group") ||
                connectionState !in setOf("disconnected", "connecting", "connected", "suspended") ||
                volumeLevel != null && volumeLevel !in 0..100) invalid()
            return CoreCastRoute(
                id, name, kind, available, connectionState, volumeLevel,
            )
        }

        private fun integer(value: Any): Int = when (value) {
            is Int -> value
            is Long -> value.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt() ?: invalid()
            else -> invalid()
        }

        private fun invalid(): Nothing = throw CoreCastRouteRejected("invalidState")
    }
}

data class CoreCastRouteSnapshot(
    val revision: Long,
    val routes: List<CoreCastRoute>,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "revision" to revision,
        "routes" to routes.map(CoreCastRoute::toMap),
    )

    companion object {
        fun parse(value: Any?): CoreCastRouteSnapshot {
            val map = value as? Map<*, *> ?: invalid()
            if (map.keys != setOf("revision", "routes")) invalid()
            val revision = when (val raw = map["revision"]) {
                is Int -> raw.toLong()
                is Long -> raw
                else -> invalid()
            }
            val rawRoutes = map["routes"] as? List<*> ?: invalid()
            if (revision < 1 || rawRoutes.size > 64) invalid()
            val routes = rawRoutes.map(CoreCastRoute::parse)
            if (routes.map(CoreCastRoute::id).toSet().size != routes.size) invalid()
            return CoreCastRouteSnapshot(revision, routes)
        }

        private fun invalid(): Nothing = throw CoreCastRouteRejected("invalidState")
    }
}

class CoreCastRouteGate {
    private var current = CoreCastRouteSnapshot(0, emptyList())

    fun publish(value: CoreCastRouteSnapshot) {
        if (value.revision <= current.revision) {
            current = CoreCastRouteSnapshot(0, emptyList())
            throw CoreCastRouteRejected("stale")
        }
        current = value
    }

    fun clear() { current = CoreCastRouteSnapshot(0, emptyList()) }

    fun snapshot() = current
}
