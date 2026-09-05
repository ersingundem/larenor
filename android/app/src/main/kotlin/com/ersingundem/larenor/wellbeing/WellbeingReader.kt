package com.ersingundem.larenor.wellbeing

import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.CancellationException

enum class WellbeingMetric(val permission: String) {
    bodyMass("android.permission.health.READ_WEIGHT"),
    bodyFatPercentage("android.permission.health.READ_BODY_FAT"),
    steps("android.permission.health.READ_STEPS");
    companion object {
        fun parse(raw: Any?): List<WellbeingMetric> {
            require(raw is List<*> && raw.size in 1..3)
            val found = raw.map { value -> entries.firstOrNull { it.name == value }
                ?: throw IllegalArgumentException("Invalid metrics") }
            require(found.distinct().size == found.size)
            return entries.filter { it in found }
        }
    }
}

class WellbeingReadRequest(
    val metrics: List<WellbeingMetric>, val start: Long, val end: Long, val limit: Int,
) {
    companion object {
        const val MAX_RECORDS = 500
        const val MAX_RANGE_MILLIS = 30L * 24 * 60 * 60 * 1000
        fun parse(raw: Any?, now: Long): WellbeingReadRequest {
            require(raw is Map<*, *> && raw.keys == setOf("metrics", "startMillis", "endMillis", "maxRecords"))
            val metrics = WellbeingMetric.parse(raw["metrics"])
            fun number(key: String): Long = when (val value = raw[key]) {
                is Long -> value
                is Int -> value.toLong()
                else -> throw IllegalArgumentException("Invalid range")
            }
            val start = number("startMillis")
            val end = number("endMillis")
            val limit = number("maxRecords")
            require(start >= 0 && end > start && end <= now + 60_000)
            require(end - start <= MAX_RANGE_MILLIS)
            require(limit in metrics.size.toLong()..MAX_RECORDS.toLong())
            return WellbeingReadRequest(metrics, start, end, limit.toInt())
        }
    }
}

/** Intentionally no data-class toString: records stay out of diagnostic output. */
class WellbeingMeasurement(
    val id: String, val value: Double, val time: Long,
    val end: Long? = null, val origin: String? = null,
) {
    fun validate(metric: WellbeingMetric, request: WellbeingReadRequest) {
        require(id.isNotEmpty() && id.length <= 256 && id.none { it.code < 32 || it.code == 127 })
        require(value.isFinite() && value >= 0)
        require(time >= request.start && time < request.end)
        require(origin == null || (origin.length <= 160 && origin.none { it.code < 32 || it.code == 127 }))
        if (metric == WellbeingMetric.bodyFatPercentage) require(value <= 100)
        if (metric == WellbeingMetric.steps) {
            require(value <= 9_007_199_254_740_991.0 && value == kotlin.math.floor(value))
            require(end != null && end > time && end <= request.end)
        } else require(end == null)
    }
    fun packet(): Map<String, Any?> = mapOf("id" to id, "value" to value,
        "timeMillis" to time, "endMillis" to end, "originName" to origin)
}

class WellbeingPage(val records: List<WellbeingMeasurement>, val next: String?)
interface WellbeingBackend {
    fun availability(): String
    suspend fun granted(): Set<WellbeingMetric>
    suspend fun page(metric: WellbeingMetric, start: Long, end: Long,
        limit: Int, token: String?): WellbeingPage
    suspend fun steps(start: Long, end: Long): Long?
}

/** No request queue, background worker, automatic retries, or writable API. */
class WellbeingReader(private val backend: WellbeingBackend) {
    companion object {
        const val PAGE_SIZE = 100
        const val MAX_PAGES = 8
        const val MAX_DAY_BUCKETS = 32
        fun dayIntervals(start: Long, end: Long, zone: ZoneId): List<Pair<Long, Long>> {
            require(start >= 0 && end > start && end - start <= WellbeingReadRequest.MAX_RANGE_MILLIS)
            val output = mutableListOf<Pair<Long, Long>>()
            var cursor = start
            while (cursor < end) {
                require(output.size < MAX_DAY_BUCKETS)
                val midnight = Instant.ofEpochMilli(cursor).atZone(zone).toLocalDate()
                    .plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
                val until = minOf(midnight, end)
                require(until > cursor)
                output.add(cursor to until)
                cursor = until
            }
            return output
        }
    }
    suspend fun read(request: WellbeingReadRequest, zone: ZoneId,
        current: () -> Boolean): List<Map<String, Any?>> {
        fun check() { if (!current()) throw CancellationException("cancelled") }
        suspend fun allowed(metric: WellbeingMetric) {
            check()
            val granted = backend.granted()
            check()
            if (metric !in granted) throw SecurityException("permission")
        }
        val output = mutableListOf<Map<String, Any?>>()
        val budget = request.limit / request.metrics.size
        for (metric in request.metrics) {
            check()
            val records = linkedMapOf<String, WellbeingMeasurement>()
            var truncated = false
            var failure: String? = null
            try {
                if (backend.availability() != "available") {
                    failure = "unavailable"
                } else if (metric == WellbeingMetric.steps) {
                    val intervals = dayIntervals(request.start, request.end, zone)
                    // Most recent calendar buckets fit even a small explicit budget.
                    for ((start, end) in intervals.asReversed()) {
                        if (records.size == budget) { truncated = true; break }
                        allowed(metric)
                        val count = backend.steps(start, end)
                        check()
                        if (count != null) {
                            val item = WellbeingMeasurement("steps:$start:$end", count.toDouble(), start, end)
                            item.validate(metric, request)
                            records[item.id] = item
                        }
                    }
                    allowed(metric)
                } else {
                    var token: String? = null
                    val seenTokens = mutableSetOf<String>()
                    var pages = 0
                    do {
                        allowed(metric)
                        val pageSize = minOf(PAGE_SIZE, budget - records.size)
                        val response = backend.page(metric, request.start, request.end, pageSize, token)
                        check()
                        require(response.records.size <= pageSize)
                        for (item in response.records) {
                            item.validate(metric, request)
                            records.putIfAbsent(item.id, item)
                        }
                        pages++
                        token = response.next
                        require(token == null || (token.isNotEmpty() && token.length <= 4096 && seenTokens.add(token)))
                        if (token != null && (records.size >= budget || pages >= MAX_PAGES)) {
                            truncated = true
                            break
                        }
                    } while (token != null)
                    allowed(metric)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: SecurityException) { failure = "permission" }
            catch (_: Exception) { failure = "readFailed" }
            check()
            output.add(mapOf("metric" to metric.name,
                "state" to if (failure != null) "failed" else if (records.isEmpty()) "empty" else "data",
                "failure" to failure,
                "truncated" to (failure == null && truncated),
                "records" to if (failure != null) emptyList<Map<String, Any?>>() else
                    records.values.sortedByDescending { it.time }.map { it.packet() }))
        }
        check()
        // A permission for an earlier metric may have been revoked while a
        // later metric was loading. No previously read values survive that.
        val finalPermissions = if (output.all { it["state"] == "failed" }) emptySet()
            else try { backend.granted() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { null }
        check()
        return output.map { result ->
            val metric = request.metrics.first { it.name == result["metric"] }
            if (finalPermissions != null && metric in finalPermissions) result
            else if (result["state"] == "failed") result
            else mapOf("metric" to metric.name, "state" to "failed",
                "failure" to if (finalPermissions == null) "readFailed" else "permission",
                "truncated" to false, "records" to emptyList<Map<String, Any?>>())
        }
    }
}
