package com.ersingundem.larenor.wellbeing

import android.content.Context
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.BodyFatRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import java.time.Instant

class HealthConnectBackend(private val context: Context) : WellbeingBackend {
    // Client construction is deferred until an explicit probe/read requests it.
    private var cached: HealthConnectClient? = null
    private fun client(): HealthConnectClient = cached ?: HealthConnectClient.getOrCreate(context)
        .also { cached = it }
    override fun availability(): String = if (Build.VERSION.SDK_INT < 28) "unavailableOnDevice" else try {
        when (HealthConnectClient.getSdkStatus(context)) {
            HealthConnectClient.SDK_AVAILABLE -> "available"
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> "installOrUpdateRequired"
            else -> "unavailableOnDevice"
        }
    } catch (_: Exception) { "unavailableOnDevice" }

    override suspend fun granted(): Set<WellbeingMetric> {
        val permissions = client().permissionController.getGrantedPermissions()
        return WellbeingMetric.entries.filter { it.permission in permissions }.toSet()
    }
    override suspend fun page(metric: WellbeingMetric, start: Long, end: Long,
        limit: Int, token: String?): WellbeingPage {
        require(limit in 1..WellbeingReader.PAGE_SIZE)
        val range = TimeRangeFilter.between(Instant.ofEpochMilli(start), Instant.ofEpochMilli(end))
        return when (metric) {
            WellbeingMetric.bodyMass -> {
                val page = client().readRecords(ReadRecordsRequest(WeightRecord::class,
                    range, ascendingOrder = false, pageSize = limit, pageToken = token))
                WellbeingPage(page.records.map { WellbeingMeasurement(it.metadata.id,
                    it.weight.inKilograms, it.time.toEpochMilli(), origin = origin(it.metadata.dataOrigin.packageName)) }, page.pageToken)
            }
            WellbeingMetric.bodyFatPercentage -> {
                val page = client().readRecords(ReadRecordsRequest(BodyFatRecord::class,
                    range, ascendingOrder = false, pageSize = limit, pageToken = token))
                WellbeingPage(page.records.map { WellbeingMeasurement(it.metadata.id,
                    it.percentage.value, it.time.toEpochMilli(), origin = origin(it.metadata.dataOrigin.packageName)) }, page.pageToken)
            }
            WellbeingMetric.steps -> throw IllegalArgumentException("Steps require aggregation")
        }
    }
    override suspend fun steps(start: Long, end: Long): Long? {
        val result = client().aggregate(AggregateRequest(metrics = setOf(StepsRecord.COUNT_TOTAL),
            timeRangeFilter = TimeRangeFilter.between(Instant.ofEpochMilli(start), Instant.ofEpochMilli(end))))
        // SDK aggregation applies Health Connect's source-priority semantics;
        // absence is unknown/empty, never converted to a fabricated zero.
        return result[StepsRecord.COUNT_TOTAL]
    }
    private fun origin(packageName: String): String? = packageName.takeIf {
        it.length in 1..160 && it.all { char -> char.isLetterOrDigit() || char == '.' || char == '_' }
    }
}
