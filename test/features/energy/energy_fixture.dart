import 'dart:async';

import 'package:larenor/features/energy/data/energy_api.dart';
import 'package:larenor/features/energy/data/energy_period.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';

final energyNow = DateTime.utc(2026, 9, 5, 12, 30);
Map<String, dynamic> energyPreferences({
  List<Map<String, dynamic>>? sources,
  List<Map<String, dynamic>> devices = const [],
}) => {
  'energy_sources':
      sources ??
      [
        {'type': 'grid', 'stat_energy_from': 'sensor.grid'},
      ],
  'device_consumption': devices,
};
Map<String, dynamic> energyMetadata(
  String id, {
  String unit = 'kWh',
  String? unitClass = 'energy',
  bool hasSum = true,
}) => {
  'statistic_id': id,
  'statistics_unit_of_measurement': unit,
  'unit_class': unitClass,
  'has_sum': hasSum,
  'name': id,
};
Map<String, dynamic> energyPoint(
  DateTime start,
  double? change, {
  DateTime? end,
}) => {
  'start': start.millisecondsSinceEpoch,
  'end': (end ?? start.add(const Duration(hours: 1))).millisecondsSinceEpoch,
  'change': change,
};

class FakeEnergyApi implements EnergyApi {
  FakeEnergyApi({DateTime? now}) : now = now ?? energyNow;
  final DateTime now;
  String timeZone = 'UTC';
  String currency = 'TRY';
  Object? prefsError,
      configError,
      infoError,
      metadataError,
      dailyError,
      hourlyError;
  Object? prefs;
  Map<String, dynamic> information = {'cost_sensors': <String, dynamic>{}};
  Map<String, Map<String, dynamic>> metadata = {};
  Map<String, List<Map<String, dynamic>>>? daily, hourly;
  final calls = <String>[];
  final batches = <List<String>>[];
  Completer<void>? gate;
  int active = 0, maxActive = 0;
  Future<void> _start(String name, Object? error) async {
    calls.add(name);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (gate != null) await gate!.future;
      if (error != null) throw error;
    } finally {
      active--;
    }
  }

  @override
  Future<Map<String, dynamic>> getConfig() async {
    await _start('config', configError);
    return {'time_zone': timeZone, 'currency': currency};
  }

  @override
  Future<Object?> getPreferences() async {
    await _start('prefs', prefsError);
    return prefs ?? energyPreferences();
  }

  @override
  Future<Object?> getInformation() async {
    await _start('info', infoError);
    return information;
  }

  @override
  Future<Object?> getMetadata(List<String> statisticIds) async {
    await _start('metadata', metadataError);
    batches.add(List.of(statisticIds));
    return [for (final id in statisticIds) metadata[id] ?? energyMetadata(id)];
  }

  @override
  Future<Object?> getStatistics({
    required List<String> statisticIds,
    required DateTime start,
    required DateTime endInclusive,
    required bool hourly,
  }) async {
    await _start(hourly ? 'hour' : 'day', hourly ? hourlyError : dailyError);
    batches.add(List.of(statisticIds));
    final overrides = hourly ? this.hourly : daily;
    if (overrides != null) {
      return {
        for (final id in statisticIds)
          if (overrides.containsKey(id)) id: overrides[id],
      };
    }
    if (hourly) {
      return {
        for (final id in statisticIds)
          id: [
            for (
              var hour = energyHourFloor(start);
              hour.isBefore(energyHourFloor(now)) &&
                  hour.isBefore(endInclusive);
              hour = hour.add(const Duration(hours: 1))
            )
              energyPoint(hour, 1),
          ],
      };
    }
    final period = buildEnergyPeriod(
      timeZone,
      now,
      endInclusive.difference(start).inDays > 1
          ? EnergyRange.last7Days
          : EnergyRange.today,
    );
    return {
      for (final id in statisticIds)
        id: [
          for (final day in period.days)
            energyPoint(day.start, 3, end: day.endExclusive),
        ],
    };
  }
}
