import 'package:timezone/timezone.dart' as tz;

import '../../today/data/today_timezone.dart';
import '../domain/energy_models.dart';

/// Consecutive HA-local midnights, not fixed 24-hour offsets. The timezone
/// must come from HA config; a missing/unknown zone never uses the device zone.
EnergyPeriod buildEnergyPeriod(
  String timeZone,
  DateTime now,
  EnergyRange range,
) {
  try {
    final location = TodayTimeZone(timeZone).location;
    final local = tz.TZDateTime.from(now, location);
    final count = range == EnergyRange.today ? 1 : 7;
    final days = <EnergyDayWindow>[];
    for (var offset = count - 1; offset >= 0; offset--) {
      final start = tz.TZDateTime(
        location,
        local.year,
        local.month,
        local.day - offset,
      );
      final end = tz.TZDateTime(
        location,
        local.year,
        local.month,
        local.day - offset + 1,
      );
      if (!end.isAfter(start)) {
        throw const EnergyException(EnergyFailure.invalidTimezone);
      }
      days.add(
        EnergyDayWindow(
          localDate:
              '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}',
          start: DateTime.fromMicrosecondsSinceEpoch(
            start.microsecondsSinceEpoch,
            isUtc: true,
          ),
          endExclusive: DateTime.fromMicrosecondsSinceEpoch(
            end.microsecondsSinceEpoch,
            isUtc: true,
          ),
        ),
      );
    }
    return EnergyPeriod(
      range: range,
      timeZone: timeZone,
      days: days,
      observedAt: now.toUtc(),
    );
  } catch (_) {
    throw const EnergyException(EnergyFailure.invalidTimezone);
  }
}

DateTime energyHourFloor(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  (value.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerHour) *
      Duration.millisecondsPerHour,
  isUtc: true,
);
DateTime energyHourCeil(DateTime value) {
  final floor = energyHourFloor(value);
  return floor == value.toUtc() ? floor : floor.add(const Duration(hours: 1));
}
