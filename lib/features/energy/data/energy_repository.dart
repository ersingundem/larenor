import 'dart:async';

import 'package:http/http.dart' as http;

import '../../ha_client/data/ha_api_exception.dart';
import '../domain/energy_models.dart';
import 'energy_api.dart';
import 'energy_configuration.dart';
import 'energy_period.dart';
import 'energy_statistics.dart';

class _Read<T> {
  const _Read(this.value, this.issue, {this.notConfigured = false});
  final T? value;
  final EnergyIssue? issue;
  final bool notConfigured;
}

class EnergyReadCancelled implements Exception {
  const EnergyReadCancelled();
}

/// Bounded read batches, no raw-state arithmetic or household/device summation.
class EnergyRepository {
  EnergyRepository({required this.api, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final EnergyApi api;
  final DateTime Function() _now;

  Future<EnergySnapshot> load(
    EnergyRange range, {
    required bool Function() isCurrent,
  }) async {
    void check() {
      if (!isCurrent()) throw const EnergyReadCancelled();
    }

    Future<_Read<T>> read<T>(
      EnergySource source,
      Future<T> Function() operation, {
      bool preferences = false,
    }) async {
      check();
      try {
        final value = await operation().timeout(const Duration(seconds: 20));
        check();
        return _Read(value, null);
      } on EnergyReadCancelled {
        rethrow;
      } catch (error) {
        check();
        if (preferences &&
            error is HaApiException &&
            error.code == 'not_found') {
          return _Read(null, null, notConfigured: true);
        }
        return _Read(null, EnergyIssue(source, classifyEnergyFailure(error)));
      }
    }

    final now = _now().toUtc();
    final first = await Future.wait<Object>([
      read(EnergySource.configuration, api.getConfig),
      read(EnergySource.preferences, api.getPreferences, preferences: true),
      read(EnergySource.information, () async {
        final value = energyObject(await api.getInformation());
        final costs = energyObject(value['cost_sensors'] ?? {});
        if (costs.length > 512) {
          throw const EnergyException(EnergyFailure.limitExceeded);
        }
        for (final entry in costs.entries) {
          energyStatisticId(entry.key);
          energyStatisticId(entry.value);
        }
        return value;
      }),
    ]);
    check();
    final config = first[0] as _Read<Map<String, dynamic>>;
    final prefs = first[1] as _Read<Object?>;
    final info = first[2] as _Read<Map<String, dynamic>>;
    final issues = <EnergyIssue>[
      if (config.issue != null) config.issue!,
      if (prefs.issue != null) prefs.issue!,
      if (info.issue != null) info.issue!,
    ];
    EnergyPeriod? period;
    if (config.value != null) {
      try {
        final zone = config.value!['time_zone'];
        if (zone is! String || zone.isEmpty) {
          throw const EnergyException(EnergyFailure.invalidTimezone);
        }
        period = buildEnergyPeriod(zone, now, range);
      } catch (_) {
        issues.add(
          const EnergyIssue(
            EnergySource.configuration,
            EnergyFailure.invalidTimezone,
          ),
        );
      }
    }
    if (prefs.notConfigured || prefs.value == null) {
      if (!prefs.notConfigured && prefs.value == null && prefs.issue == null) {
        issues.add(
          const EnergyIssue(
            EnergySource.preferences,
            EnergyFailure.invalidResponse,
          ),
        );
      }
      return EnergySnapshot(
        energyConfigured: prefs.notConfigured ? false : null,
        period: period,
        readAt: now,
        issues: issues,
      );
    }
    final EnergyConfiguration configuration;
    try {
      configuration = parseEnergyConfiguration(
        prefs.value,
        information: info.value,
      );
    } catch (error) {
      return EnergySnapshot(
        energyConfigured: null,
        period: period,
        readAt: now,
        issues: [
          ...issues,
          EnergyIssue(EnergySource.preferences, classifyEnergyFailure(error)),
        ],
      );
    }
    issues.addAll(configuration.issues);
    if (period == null || configuration.meters.isEmpty) {
      return EnergySnapshot(
        energyConfigured: true,
        period: period,
        readAt: now,
        costsConfigured: configuration.costsConfigured,
        issues: issues,
      );
    }
    final ids =
        configuration.meters.map((meter) => meter.statisticId).toSet().toList()
          ..sort();
    final metadata = <String, EnergyStatisticMetadata>{};
    final batchSize = 32;
    for (var offset = 0; offset < ids.length; offset += batchSize) {
      final batch = ids.sublist(
        offset,
        (offset + batchSize).clamp(0, ids.length),
      );
      final value = await read(
        EnergySource.metadata,
        () async =>
            parseEnergyMetadata(await api.getMetadata(batch), batch.toSet()),
      );
      if (value.issue != null) issues.add(value.issue!);
      metadata.addAll(value.value ?? {});
    }
    final currency = config.value?['currency'] is String
        ? config.value!['currency'] as String
        : null;
    final invalidIds = configuration.issues
        .where(
          (issue) =>
              issue.failure == EnergyFailure.conflictingStatistic ||
              issue.failure == EnergyFailure.invalidHierarchy,
        )
        .map((issue) => issue.statisticId)
        .whereType<String>()
        .toSet();
    final units = <String, String>{};
    for (final meter in configuration.meters) {
      final meta = metadata[meter.statisticId];
      final unit = meta?.outputUnit(meter.role, currency);
      if (meta == null || unit == null) {
        issues.add(
          EnergyIssue(
            EnergySource.metadata,
            meta == null
                ? EnergyFailure.missingMetadata
                : EnergyFailure.unsupportedUnit,
            statisticId: meter.statisticId,
          ),
        );
      } else if (!invalidIds.contains(meter.statisticId)) {
        units[meter.statisticId] = unit;
      }
    }
    final validIds = units.keys.toList()..sort();
    final dailyValues = <String, List<EnergyStatisticPoint>>{};
    final hourlyValues = <String, List<EnergyStatisticPoint>>{};
    final invalidDaily = <String>{};
    final invalidHourly = <String>{};
    final coverageStart = energyHourCeil(period.start)
        .subtract(const Duration(hours: 1));
    final coverageEnd = now.isBefore(period.endExclusive)
        ? now
        : period.endExclusive.subtract(const Duration(milliseconds: 1));
    for (var offset = 0; offset < validIds.length; offset += batchSize) {
      final batch = validIds.sublist(
        offset,
        (offset + batchSize).clamp(0, validIds.length),
      );
      // At most two requests in flight, with at most 32 IDs and 200 hours each.
      final reads = await Future.wait([
        read(
          EnergySource.daily,
          () async => parseEnergyStatistics(
            await api.getStatistics(
              statisticIds: batch,
              start: period!.start,
              endInclusive: period.dailyRequestEnd,
              hourly: false,
            ),
            batch.toSet(),
            hourly: false,
          ),
        ),
        read(
          EnergySource.hourly,
          () async => parseEnergyStatistics(
            await api.getStatistics(
              statisticIds: batch,
              start: coverageStart,
              endInclusive: coverageEnd,
              hourly: true,
            ),
            batch.toSet(),
            hourly: true,
          ),
        ),
      ]);
      for (final value in reads) {
        if (value.issue != null) issues.add(value.issue!);
      }
      dailyValues.addAll(reads[0].value?.values ?? {});
      hourlyValues.addAll(reads[1].value?.values ?? {});
      invalidDaily.addAll(reads[0].value?.invalidIds ?? {});
      invalidHourly.addAll(reads[1].value?.invalidIds ?? {});
    }
    check();
    final readings = <EnergyMeterReading>[];
    for (final meter in configuration.meters) {
      final id = meter.statisticId;
      final meterIssues = [
        for (final issue in issues)
          if (issue.statisticId == id ||
              (issue.statisticId == null &&
                  {
                    EnergySource.metadata,
                    EnergySource.daily,
                    EnergySource.hourly,
                  }.contains(issue.source)))
            issue,
      ];
      if (invalidDaily.contains(id)) {
        meterIssues.add(
          EnergyIssue(
            EnergySource.daily,
            EnergyFailure.invalidResponse,
            statisticId: id,
          ),
        );
      }
      if (invalidHourly.contains(id)) {
        meterIssues.add(
          EnergyIssue(
            EnergySource.hourly,
            EnergyFailure.invalidResponse,
            statisticId: id,
          ),
        );
      }
      readings.add(
        EnergyMeterReading(
          definition: meter,
          name: meter.name ?? metadata[id]?.name ?? id,
          unit: units[id],
          daily: energyDailyReadings(
            period: period,
            role: meter.role,
            daily: dailyValues[id] ?? [],
            hourly: hourlyValues[id] ?? [],
            invalid: invalidDaily.contains(id) || units[id] == null,
          ),
          issues: meterIssues,
        ),
      );
    }
    return EnergySnapshot(
      energyConfigured: true,
      period: period,
      readAt: now,
      meters: readings,
      issues: issues,
      costsConfigured: configuration.costsConfigured,
    );
  }
}

EnergyFailure classifyEnergyFailure(Object error) {
  if (error is EnergyException) return error.failure;
  if (error is TimeoutException) return EnergyFailure.timeout;
  if (error is HaApiException) {
    if (error.statusCode == 401 || error.code == 'auth_invalid') {
      return EnergyFailure.authentication;
    }
    if (error.statusCode == 403 ||
        {'unauthorized', 'forbidden'}.contains(error.code)) {
      return EnergyFailure.permission;
    }
    if (error.code == 'timeout') return EnergyFailure.timeout;
    if (error.code == 'invalid_response') return EnergyFailure.invalidResponse;
    return EnergyFailure.transport;
  }
  if (error is FormatException || error is TypeError) {
    return EnergyFailure.invalidResponse;
  }
  if (error is http.ClientException) return EnergyFailure.transport;
  return EnergyFailure.transport;
}
