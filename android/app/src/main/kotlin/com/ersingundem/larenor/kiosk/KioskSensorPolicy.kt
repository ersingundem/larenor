package com.ersingundem.larenor.kiosk

import kotlin.math.max
import kotlin.math.min

data class KioskSensorAvailability(
    val light: Boolean,
    val motion: Boolean,
    val approach: Boolean = false,
    val approachMaxRangeCm: Double? = null,
    val camera: String = "unavailable",
) {
    init {
        require(camera in setOf("available", "busy", "permissionDenied", "unavailable"))
        require(
            if (approach) approachMaxRangeCm != null && approachMaxRangeCm.isFinite() &&
                approachMaxRangeCm in 0.1..100.0
            else approachMaxRangeCm == null,
        )
    }
}

sealed interface KioskSensorSample {
    val observedAtElapsedMillis: Long

    data class Light(val lux: Double, override val observedAtElapsedMillis: Long) : KioskSensorSample
    data class Motion(val delta: Double, override val observedAtElapsedMillis: Long) : KioskSensorSample
    data class Approach(val distanceCm: Double, override val observedAtElapsedMillis: Long) : KioskSensorSample
}

interface KioskSensorHost {
    fun availability(): KioskSensorAvailability
    fun start(listener: (KioskSensorSample) -> Unit)
    fun stop()
    fun nowMillis(): Long
    fun token(): String
}

/** Owns a single foreground-only, memory-only sensor session. */
class KioskSensorPolicy(private val host: KioskSensorHost) {
    private data class Session(
        val id: String,
        val intervalMillis: Long,
        var sequence: Long,
        var observedAt: Long,
        var lux: Double?,
        var motionDelta: Double?,
        var approachDistanceCm: Double?,
        var lastLightAt: Long?,
        var lastMotionAt: Long?,
        var lastApproachAt: Long?,
    )

    private var interactive = false
    private var disposed = false
    private var session: Session? = null

    @Synchronized
    fun setInteractive(value: Boolean) {
        if (disposed) return
        interactive = value
        if (!value) retire()
    }

    @Synchronized
    fun start(raw: Any?): Map<String, Any?> {
        checkAlive()
        if (!interactive) throw KioskFailure("denied")
        if (session != null) throw KioskFailure("busy")
        val input = raw as? Map<*, *> ?: throw KioskFailure("invalid")
        if (input.size != 1) throw KioskFailure("invalid")
        val interval = (input["intervalMillis"] as? Int)?.toLong()
            ?: throw KioskFailure("invalid")
        if (interval !in 1000L..10000L) throw KioskFailure("invalid")
        val id = host.token()
        if (!SESSION.matches(id)) throw KioskFailure("unavailable")
        try {
            host.start(::accept)
        } catch (_: RuntimeException) {
            host.stop()
            throw KioskFailure("unavailable")
        }
        session = Session(
            id = id,
            intervalMillis = interval,
            sequence = 0,
            observedAt = max(0, host.nowMillis()),
            lux = null,
            motionDelta = null,
            approachDistanceCm = null,
            lastLightAt = null,
            lastMotionAt = null,
            lastApproachAt = null,
        )
        return snapshot(session!!)
    }

    @Synchronized
    fun read(raw: Any?): Map<String, Any?> {
        checkAlive()
        val active = exactSession(raw)
        if (!interactive) throw KioskFailure("expired")
        return snapshot(active)
    }

    @Synchronized
    fun stop(raw: Any?): Map<String, Any?> {
        checkAlive()
        val active = exactSession(raw)
        retire()
        return mapOf("version" to 1, "sessionId" to active.id, "stopped" to true)
    }

    @Synchronized
    private fun accept(sample: KioskSensorSample) {
        val active = session ?: return
        if (!interactive || disposed || sample.observedAtElapsedMillis < 0) return
        when (sample) {
            is KioskSensorSample.Light -> {
                val last = active.lastLightAt
                if (last != null && sample.observedAtElapsedMillis - last < active.intervalMillis) return
                if (!sample.lux.isFinite() || sample.lux < 0) return
                active.lux = min(sample.lux, 200000.0)
                active.lastLightAt = sample.observedAtElapsedMillis
            }
            is KioskSensorSample.Motion -> {
                val last = active.lastMotionAt
                if (last != null && sample.observedAtElapsedMillis - last < active.intervalMillis) return
                if (!sample.delta.isFinite() || sample.delta < 0) return
                active.motionDelta = min(sample.delta, 100.0)
                active.lastMotionAt = sample.observedAtElapsedMillis
            }
            is KioskSensorSample.Approach -> {
                val last = active.lastApproachAt
                if (last != null && sample.observedAtElapsedMillis - last < active.intervalMillis) return
                if (!sample.distanceCm.isFinite() || sample.distanceCm < 0) return
                active.approachDistanceCm = min(sample.distanceCm, 100.0)
                active.lastApproachAt = sample.observedAtElapsedMillis
            }
        }
        active.sequence++
        active.observedAt = max(active.observedAt, sample.observedAtElapsedMillis)
    }

    private fun exactSession(raw: Any?): Session {
        val input = raw as? Map<*, *> ?: throw KioskFailure("invalid")
        if (input.size != 1) throw KioskFailure("invalid")
        val id = input["sessionId"] as? String ?: throw KioskFailure("invalid")
        return session?.takeIf { it.id == id } ?: throw KioskFailure("expired")
    }

    private fun snapshot(active: Session): Map<String, Any?> {
        val availability = try { host.availability() } catch (_: RuntimeException) {
            throw KioskFailure("unavailable")
        }
        return mapOf(
            "version" to 2,
            "sessionId" to active.id,
            "sequence" to active.sequence,
            "sampling" to true,
            "lightAvailable" to availability.light,
            "motionAvailable" to availability.motion,
            "approachAvailable" to availability.approach,
            "observedAtElapsedMillis" to active.observedAt,
            "lux" to if (availability.light) active.lux else null,
            "motionDelta" to if (availability.motion) active.motionDelta else null,
            "approachDistanceCm" to if (availability.approach) {
                active.approachDistanceCm?.let { distance ->
                    min(distance, availability.approachMaxRangeCm!!)
                }
            } else null,
            "approachMaxRangeCm" to availability.approachMaxRangeCm,
            "cameraStatus" to availability.camera,
        )
    }

    @Synchronized
    fun hasSession() = session != null

    private fun retire() {
        if (session == null) return
        session = null
        try { host.stop() } catch (_: RuntimeException) { /* already retired */ }
    }

    @Synchronized
    fun dispose() {
        if (disposed) return
        disposed = true
        interactive = false
        retire()
    }

    private fun checkAlive() {
        if (disposed) throw KioskFailure("unavailable")
    }

    companion object {
        private val SESSION = Regex("^[a-f0-9-]{36}$")
    }
}
