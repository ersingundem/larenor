import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy/data/energy_period.dart';
import 'package:larenor/features/energy/data/energy_statistics.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';

import 'energy_fixture.dart';

EnergyPeriod _completePeriod(String zone, DateTime inDay) {
  final original = buildEnergyPeriod(zone, inDay, EnergyRange.today);
  return EnergyPeriod(
    range: EnergyRange.today,
    timeZone: zone,
    days: original.days,
    observedAt: original.endExclusive.add(const Duration(hours: 1)),
  );
}

List<EnergyStatisticPoint> _hours(
  EnergyPeriod period, {
  bool baseline = true,
}) => [
  for (
    var hour = energyHourCeil(period.start)
        .subtract(Duration(hours: baseline ? 1 : 0));
    hour.isBefore(energyHourFloor(period.endExclusive));
    hour = hour.add(const Duration(hours: 1))
  )
    EnergyStatisticPoint(hour, hour.add(const Duration(hours: 1)), 1),
];
List<EnergyDayReading> _read(
  EnergyPeriod period, {
  List<EnergyStatisticPoint>? hourly,
  double? value = 3,
  EnergyRole role = EnergyRole.gridImport,
  List<EnergyStatisticPoint>? daily,
}) => energyDailyReadings(
  period: period,
  role: role,
  daily:
      daily ?? [EnergyStatisticPoint(period.start, period.endExclusive, value)],
  hourly: hourly ?? _hours(period),
);

void main() {
  for (final fixture in [
    (DateTime.utc(2026, 3, 29, 12), 23),
    (DateTime.utc(2026, 10, 25, 12), 25),
  ]) {
    test('HA daily bucket checks ${fixture.$2} real UTC hours through DST', () {
      final period = _completePeriod('Europe/Berlin', fixture.$1);
      final reading = _read(period).single;
      expect(reading.expectedHours, fixture.$2);
      expect(reading.receivedHours, fixture.$2);
      expect(reading.hasBaseline, isTrue);
      expect(reading.issues, isEmpty);
    });
  }
  test('daily result alone cannot establish baseline or hourly coverage', () {
    final period = _completePeriod('UTC', energyNow);
    final missing = _read(period, hourly: []).single;
    expect(missing.reportedValue, 3);
    expect(
      missing.issues,
      containsAll([
        EnergyCoverageIssue.missingBaseline,
        EnergyCoverageIssue.hourlyGap,
      ]),
    );
    final noBaseline = _read(
      period,
      hourly: _hours(period, baseline: false),
    ).single;
    expect(noBaseline.receivedHours, noBaseline.expectedHours);
    expect(noBaseline.issues, {EnergyCoverageIssue.missingBaseline});
  });
  test(
    'a missing middle hour remains a gap despite later cumulative daily change',
    () {
      final period = _completePeriod('UTC', energyNow);
      final hours = _hours(period)..removeAt(9);
      final value = _read(period, hourly: hours).single;
      expect(value.reportedValue, 3);
      expect(value.receivedHours, 23);
      expect(value.issues, {EnergyCoverageIssue.hourlyGap});
    },
  );
  test('half-hour and quarter-hour zones stay boundary-limited even with all whole UTC hours', () {
    for (final zone in ['Asia/Kolkata', 'Asia/Kathmandu']) {
      final period = _completePeriod(zone, energyNow);
      final value = _read(period).single;
      expect(value.receivedHours, value.expectedHours);
      expect(value.issues, {EnergyCoverageIssue.boundaryLimited});
    }
  });
  test('current day is ongoing; future hours are not falsely called historical gaps', () {
    final period = buildEnergyPeriod('UTC', energyNow, EnergyRange.today);
    final hourly = _hours(period)
        .where((point) => !point.end.isAfter(energyHourFloor(energyNow)))
        .toList();
    final value = _read(period, hourly: hourly).single;
    expect(value.expectedHours, 12);
    expect(value.receivedHours, 12);
    expect(value.issues, {EnergyCoverageIssue.ongoing});
  });
  test('end-exclusive filtering rejects extra following day and wrong daily boundaries', () {
    final period = _completePeriod('UTC', energyNow);
    final value = _read(
      period,
      daily: [
        EnergyStatisticPoint(period.start, period.endExclusive, 3),
        EnergyStatisticPoint(
          period.endExclusive,
          period.endExclusive.add(const Duration(days: 1)),
          999,
        ),
      ],
    );
    expect(value, hasLength(1));
    expect(value.single.reportedValue, 3);
    final wrong = _read(
      period,
      daily: [
        EnergyStatisticPoint(
          period.start,
          period.endExclusive.add(const Duration(hours: 1)),
          3,
        ),
      ],
    ).single;
    expect(wrong.reportedValue, isNull);
    expect(wrong.issues, contains(EnergyCoverageIssue.missingDay));
  });
  test('null and negative energy changes stay unknown; recorded negative currency is preserved', () {
    final period = _completePeriod('UTC', energyNow);
    expect(_read(period, value: null).single.reportedValue, isNull);
    expect(_read(period, value: -1).single.reportedValue, isNull);
    expect(
      _read(period, value: -1, role: EnergyRole.gridCost).single.reportedValue,
      -1,
    );
  });
  test('recorder reset is represented by change, never subtracting raw state or sum', () {
    final start = DateTime.utc(2026, 9, 5);
    final parsed = parseEnergyStatistics(
      {
        'sensor.grid': [
          {...energyPoint(start, 2), 'state': 9999, 'sum': 10000},
          {
            ...energyPoint(start.add(const Duration(hours: 1)), 3),
            'state': 1,
            'sum': 10003,
          },
        ],
      },
      {'sensor.grid'},
      hourly: true,
    );
    expect(parsed.values['sensor.grid']!.map((point) => point.change), [2, 3]);
  });
  test('unordered, duplicate, nonfinite and malformed rows invalidate only their own meter', () {
    final start = DateTime.utc(2026, 9, 5);
    for (final bad in [
      [energyPoint(start, 1), energyPoint(start, 2)],
      [
        energyPoint(start.add(const Duration(hours: 1)), 1),
        energyPoint(start, 2),
      ],
      [energyPoint(start, double.nan)],
      [energyPoint(start, double.infinity)],
      [energyPoint(start, 1, end: start)],
      [
        {...energyPoint(start, 1), 'change': '1'},
      ],
    ]) {
      final parsed = parseEnergyStatistics(
        {
          'sensor.bad': bad,
          'sensor.good': [energyPoint(start, 0)],
        },
        {'sensor.bad', 'sensor.good'},
        hourly: true,
      );
      expect(parsed.invalidIds, {'sensor.bad'});
      expect(parsed.values['sensor.good']!.single.change, 0);
    }
  });
}
