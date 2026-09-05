import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy/data/energy_period.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';

void main() {
  test(
    'day windows follow HA spring and autumn midnights, not 24-hour arithmetic',
    () {
      final spring = buildEnergyPeriod(
        'Europe/Berlin',
        DateTime.utc(2026, 3, 29, 12),
        EnergyRange.today,
      );
      final autumn = buildEnergyPeriod(
        'Europe/Berlin',
        DateTime.utc(2026, 10, 25, 12),
        EnergyRange.today,
      );
      expect(spring.endExclusive.difference(spring.start).inHours, 23);
      expect(autumn.endExclusive.difference(autumn.start).inHours, 25);
      expect(spring.start, DateTime.utc(2026, 3, 28, 23));
      expect(autumn.endExclusive, DateTime.utc(2026, 10, 25, 23));
    },
  );
  test('seven local calendar days include today with contiguous distinct DST boundaries', () {
    final period = buildEnergyPeriod(
      'Europe/Berlin',
      DateTime.utc(2026, 3, 30, 12),
      EnergyRange.last7Days,
    );
    expect(period.days, hasLength(7));
    expect(period.days.first.localDate, '2026-03-24');
    expect(period.days.last.localDate, '2026-03-30');
    expect(period.endExclusive.difference(period.start).inHours, 167);
    for (var i = 1; i < period.days.length; i++) {
      expect(period.days[i].start, period.days[i - 1].endExclusive);
    }
    expect(period.isOngoing, isTrue);
  });
  for (final zone in ['Asia/Kolkata', 'Asia/Kathmandu']) {
    test(
      '$zone retains partial-hour boundaries and explicitly limits precision',
      () {
        final period = buildEnergyPeriod(
          zone,
          DateTime.utc(2026, 9, 5, 12),
          EnergyRange.today,
        );
        expect(period.boundaryLimited, isTrue);
        expect(period.start.minute, zone == 'Asia/Kolkata' ? 30 : 15);
        expect(period.days.single.localDate, '2026-09-05');
      },
    );
  }
  test('inclusive request end remains inside final day; internal range remains exclusive', () {
    final period = buildEnergyPeriod(
      'Europe/Istanbul',
      DateTime.utc(2026, 9, 5, 22),
      EnergyRange.today,
    );
    expect(period.days.single.localDate, '2026-09-06');
    expect(
      period.dailyRequestEnd.add(const Duration(milliseconds: 1)),
      period.endExclusive,
    );
    expect(period.days.single.contains(period.endExclusive), isFalse);
    expect(period.days.single.contains(period.dailyRequestEnd), isTrue);
  });
  test('invalid HA timezone never falls back to local device time', () {
    expect(
      () => buildEnergyPeriod(
        'Invalid/Fixture',
        DateTime.utc(2026),
        EnergyRange.today,
      ),
      throwsA(isA<EnergyException>()),
    );
    expect(
      () => buildEnergyPeriod('', DateTime.utc(2026), EnergyRange.today),
      throwsA(isA<EnergyException>()),
    );
  });
}
