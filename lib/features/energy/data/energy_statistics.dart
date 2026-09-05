import '../domain/energy_models.dart';
import 'energy_configuration.dart';
import 'energy_period.dart';

class EnergyStatisticPoint {
  const EnergyStatisticPoint(this.start, this.end, this.change);
  final DateTime start;
  final DateTime end;
  final double? change;
}

class EnergyStatistics {
  EnergyStatistics(
    Map<String, List<EnergyStatisticPoint>> values,
    Set<String> invalidIds,
  ) : values = Map.unmodifiable({
        for (final entry in values.entries)
          entry.key: List<EnergyStatisticPoint>.unmodifiable(entry.value),
      }),
      invalidIds = Set.unmodifiable(invalidIds);
  final Map<String, List<EnergyStatisticPoint>> values;
  final Set<String> invalidIds;
  static final empty = EnergyStatistics({}, {});
}

/// A malformed series does not discard independent valid meters. Rows must be
/// finite, ordered and unique; null changes stay unknown rather than zero.
EnergyStatistics parseEnergyStatistics(
  Object? raw,
  Set<String> requested, {
  required bool hourly,
}) {
  final map = energyObject(raw);
  if (map.keys.any((id) => !requested.contains(id))) {
    throw const EnergyException(EnergyFailure.invalidResponse);
  }
  final values = <String, List<EnergyStatisticPoint>>{};
  final invalid = <String>{};
  for (final entry in map.entries) {
    try {
      final rows = energyList(entry.value, hourly ? 200 : 8);
      final result = <EnergyStatisticPoint>[];
      DateTime? previous;
      for (final rawRow in rows) {
        final row = energyObject(rawRow);
        final start = _time(row['start']);
        final end = _time(row['end']);
        final change = row['change'];
        if (!end.isAfter(start) ||
            (previous != null && !start.isAfter(previous)) ||
            (hourly &&
                (end.difference(start) != const Duration(hours: 1) ||
                    start != energyHourFloor(start))) ||
            (change != null && (change is! num || !change.isFinite))) {
          throw const EnergyException(EnergyFailure.invalidResponse);
        }
        result.add(
          EnergyStatisticPoint(start, end, (change as num?)?.toDouble()),
        );
        previous = start;
      }
      values[entry.key] = result;
    } catch (_) {
      invalid.add(entry.key);
    }
  }
  return EnergyStatistics(values, invalid);
}

DateTime _time(Object? value) {
  if (value is! num ||
      !value.isFinite ||
      value != value.roundToDouble() ||
      value.abs() > 8640000000000000) {
    throw const EnergyException(EnergyFailure.invalidResponse);
  }
  return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
}

List<EnergyDayReading> energyDailyReadings({
  required EnergyPeriod period,
  required EnergyRole role,
  required List<EnergyStatisticPoint> daily,
  required List<EnergyStatisticPoint> hourly,
  bool invalid = false,
}) {
  final byDay = {for (final row in daily) row.start: row};
  final byHour = {for (final row in hourly) row.start: row};
  bool usable(EnergyStatisticPoint? point) =>
      point?.change != null && (role.isCurrency || point!.change! >= 0);
  final result = <EnergyDayReading>[];
  for (final day in period.days) {
    final issues = <EnergyCoverageIssue>{};
    final point = byDay[day.start];
    double? value;
    if (invalid) {
      issues.add(EnergyCoverageIssue.invalidData);
    } else if (point == null ||
        point.end != day.endExclusive ||
        point.change == null) {
      issues.add(EnergyCoverageIssue.missingDay);
    } else if (!usable(point)) {
      issues.add(EnergyCoverageIssue.invalidData);
    } else {
      value = point.change;
    }
    if (day.contains(period.observedAt)) {
      issues.add(EnergyCoverageIssue.ongoing);
    }
    if (day.start.millisecondsSinceEpoch % Duration.millisecondsPerHour != 0 ||
        day.endExclusive.millisecondsSinceEpoch %
                Duration.millisecondsPerHour !=
            0) {
      issues.add(EnergyCoverageIssue.boundaryLimited);
    }
    final firstHour = energyHourCeil(day.start);
    final cutoff = energyHourFloor(
      period.observedAt.isBefore(day.endExclusive)
          ? period.observedAt
          : day.endExclusive,
    );
    var expected = 0;
    var received = 0;
    for (
      var cursor = firstHour;
      cursor.isBefore(cutoff);
      cursor = cursor.add(const Duration(hours: 1))
    ) {
      expected++;
      if (usable(byHour[cursor])) received++;
    }
    final baseline = usable(
      byHour[firstHour.subtract(const Duration(hours: 1))],
    );
    if (!baseline) issues.add(EnergyCoverageIssue.missingBaseline);
    if (received != expected) issues.add(EnergyCoverageIssue.hourlyGap);
    // Future/unrecorded buckets are never invented; the ongoing flag carries
    // the distinction between hours not yet elapsed and historical gaps.
    result.add(
      EnergyDayReading(
        window: day,
        reportedValue: value,
        expectedHours: expected,
        receivedHours: received,
        hasBaseline: baseline,
        issues: issues,
      ),
    );
  }
  return List.unmodifiable(result);
}
