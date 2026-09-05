package com.ersingundem.larenor.wellbeing

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class WellbeingReaderTest {
    private val start = Instant.parse("2026-09-01T00:00:00Z").toEpochMilli()
    private val end = start + 3 * 86_400_000
    private val utc = ZoneId.of("UTC")
    private class Backend : WellbeingBackend {
        var available = "available"
        var permissions = WellbeingMetric.entries.toSet()
        var permissionReads = 0
        var pages = 0
        var aggregates = 0
        val limits = mutableListOf<Int>()
        var onPage: suspend (WellbeingMetric, Long, Long, Int, String?) -> WellbeingPage = { _, _, _, _, _ -> WellbeingPage(emptyList(), null) }
        var onSteps: suspend (Long, Long) -> Long? = { _, _ -> null }
        override fun availability() = available
        override suspend fun granted(): Set<WellbeingMetric> { permissionReads++; return permissions }
        override suspend fun page(metric: WellbeingMetric, start: Long, end: Long, limit: Int, token: String?): WellbeingPage {
            pages++; limits.add(limit); return onPage(metric, start, end, limit, token)
        }
        override suspend fun steps(start: Long, end: Long): Long? { aggregates++; return onSteps(start, end) }
    }
    private fun request(metrics: List<WellbeingMetric> = WellbeingMetric.entries, limit: Int = 500) =
        WellbeingReadRequest(metrics, start, end, limit)
    private fun packet() = mapOf("metrics" to listOf("bodyMass"), "startMillis" to start,
        "endMillis" to end, "maxRecords" to 500)

    @Test fun invalidRequestsFailBeforeAnyServiceCall() {
        for (raw in listOf(null, packet() + ("metrics" to listOf("bodyMass", "bodyMass")),
            packet() + ("metrics" to listOf("heartRate")), packet() + ("metrics" to emptyList<String>()),
            packet() + ("startMillis" to -1), packet() + ("startMillis" to end),
            packet() + ("endMillis" to (end + 60_001)),
            packet() + ("startMillis" to (end - WellbeingReadRequest.MAX_RANGE_MILLIS - 1)),
            packet() + ("maxRecords" to 501), packet() + ("maxRecords" to 0),
            packet() + ("startMillis" to start.toDouble()), packet() + ("profile" to "private"))) {
            try { WellbeingReadRequest.parse(raw, end); fail("Invalid request accepted") }
            catch (_: IllegalArgumentException) { }
        }
        assertEquals(500, WellbeingReadRequest.parse(packet(), end).limit)
    }

    @Test fun perTypePermissionsAndUnavailableAreFailuresNotEmptyRecords() = runBlocking {
        val backend = Backend().apply { permissions = setOf(WellbeingMetric.bodyMass) }
        val result = WellbeingReader(backend).read(request(), utc) { true }
        assertEquals(listOf("empty", "failed", "failed"), result.map { it["state"] })
        assertEquals("permission", result[1]["failure"])
        assertEquals(1, backend.pages)
        assertEquals(0, backend.aggregates)
        backend.available = "unavailableOnDevice"
        val before = backend.permissionReads
        val unavailable = WellbeingReader(backend).read(request(), utc) { true }
        assertTrue(unavailable.all { it["failure"] == "unavailable" })
        assertEquals(before, backend.permissionReads)
    }

    @Test fun fairBudgetAndPageSizeBoundLargeLibraryWithoutHidingPartialResults() = runBlocking {
        val backend = Backend().apply {
            onPage = { metric, at, _, limit, token ->
                val offset = token?.toInt() ?: 0
                WellbeingPage(List(limit) { WellbeingMeasurement("${metric.name}-${offset + it}",
                    if (metric == WellbeingMetric.bodyMass) 70.0 else 20.0, at + offset + it) }, (offset + limit).toString())
            }
            onSteps = { _, _ -> 42L }
        }
        val result = WellbeingReader(backend).read(request(), utc) { true }
        val counts = result.map { (it["records"] as List<*>).size }
        assertEquals(listOf(166, 166, 3), counts)
        assertTrue(counts.sum() <= 500)
        assertTrue(backend.limits.all { it in 1..100 })
        assertEquals(true, result[0]["truncated"])
        assertEquals(false, result[2]["truncated"])
        assertEquals(3, backend.aggregates)
    }

    @Test fun duplicatePagesCannotCauseUnboundedReadsAndRepeatedTokenFailsSafely() = runBlocking {
        val backend = Backend().apply { onPage = { _, at, _, _, _ ->
            WellbeingPage(listOf(WellbeingMeasurement("same", 70.0, at)), pages.toString()) } }
        val result = WellbeingReader(backend).read(request(listOf(WellbeingMetric.bodyMass)), utc) { true }.single()
        assertEquals(WellbeingReader.MAX_PAGES, backend.pages)
        assertEquals(1, (result["records"] as List<*>).size)
        assertEquals(true, result["truncated"])
        backend.onPage = { _, at, _, _, _ -> WellbeingPage(listOf(WellbeingMeasurement("same", 70.0, at)), "cycle") }
        val malformed = WellbeingReader(backend).read(request(listOf(WellbeingMetric.bodyMass)), utc) { true }.single()
        assertEquals("failed", malformed["state"])
        assertTrue((malformed["records"] as List<*>).isEmpty())
    }

    @Test fun cancellationAfterAwaitDiscardsDataAndPreventsEveryLaterMetric() = runBlocking {
        var current = true
        val backend = Backend().apply { onPage = { _, at, _, _, _ ->
            current = false
            WellbeingPage(listOf(WellbeingMeasurement("private-id", 70.0, at)), "next") } }
        try { WellbeingReader(backend).read(request(), utc) { current }; fail("Stale result escaped") }
        catch (_: CancellationException) { }
        assertEquals(1, backend.pages)
        assertEquals(0, backend.aggregates)
    }

    @Test fun permissionRevokedDuringAnotherMetricRemovesPreviouslyReadValues() = runBlocking {
        val backend = Backend().apply {
            onPage = { metric, at, _, _, _ ->
                if (metric == WellbeingMetric.bodyFatPercentage) permissions = setOf(WellbeingMetric.bodyFatPercentage)
                WellbeingPage(listOf(WellbeingMeasurement(metric.name, 20.0, at)), null)
            }
        }
        val result = WellbeingReader(backend).read(request(listOf(WellbeingMetric.bodyMass, WellbeingMetric.bodyFatPercentage)), utc) { true }
        assertEquals("permission", result[0]["failure"])
        assertTrue((result[0]["records"] as List<*>).isEmpty())
        assertEquals("data", result[1]["state"])
    }

    @Test fun stepsUseCalendarIntervalsIncludingDstAndMissingDoesNotMeanZero() = runBlocking {
        val zone = ZoneId.of("America/New_York")
        val from = ZonedDateTime.of(2026, 3, 7, 0, 0, 0, 0, zone).toInstant().toEpochMilli()
        val until = ZonedDateTime.of(2026, 3, 10, 0, 0, 0, 0, zone).toInstant().toEpochMilli()
        val intervals = WellbeingReader.dayIntervals(from, until, zone)
        assertEquals(listOf(24L, 23L, 24L), intervals.map { (it.second - it.first) / 3_600_000 })
        assertEquals(from, intervals.first().first)
        assertEquals(until, intervals.last().second)
        val backend = Backend().apply { onSteps = { _, _ -> if (aggregates == 2) 0L else null } }
        val result = WellbeingReader(backend).read(WellbeingReadRequest(listOf(WellbeingMetric.steps), from, until, 500), zone) { true }.single()
        val records = result["records"] as List<*>
        assertEquals(1, records.size)
        assertEquals(0.0, (records.single() as Map<*, *>)["value"])
        assertEquals(0, backend.pages)
        assertEquals(3, backend.aggregates)
    }

    @Test fun invalidMeasurementAndServerErrorNeverLeakPartialPrivateRecords() = runBlocking {
        val backend = Backend().apply { onPage = { _, at, _, _, _ ->
            WellbeingPage(listOf(WellbeingMeasurement("ok", 20.0, at), WellbeingMeasurement("private-id", Double.NaN, at)), null) } }
        val result = WellbeingReader(backend).read(request(listOf(WellbeingMetric.bodyMass)), utc) { true }.single()
        assertEquals("readFailed", result["failure"])
        assertTrue((result["records"] as List<*>).isEmpty())
        val measurement = WellbeingMeasurement("private-id", 74.12345, start)
        assertFalse(measurement.toString().contains("74.12345"))
        assertFalse(measurement.toString().contains("private-id"))
        backend.onPage = { _, _, _, _, _ -> throw IllegalStateException("private-server-details") }
        val failed = WellbeingReader(backend).read(request(listOf(WellbeingMetric.bodyMass)), utc) { true }.single()
        assertFalse(failed.toString().contains("private-server-details"))
    }
}
