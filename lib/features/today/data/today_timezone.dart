import 'package:timezone/data/latest.dart' as database;
import 'package:timezone/timezone.dart' as tz;

import '../domain/today_models.dart';

class TodayTimeZone {
  TodayTimeZone(String name) {
    if (!_initialized) {
      database.initializeTimeZones();
      _initialized = true;
    }
    try {
      // The compact database omits this valid Home Assistant timezone alias.
      location = name == 'UTC' ? tz.UTC : tz.getLocation(name);
    } catch (_) {
      throw const TodayException('unknown_timezone');
    }
  }
  static bool _initialized = false;
  late final tz.Location location;
  String get name => location.name;

  DateTime local(DateTime value) => tz.TZDateTime.from(value, location);

  ({DateTime start, DateTime end}) dayRange(DateTime now) {
    final localNow = tz.TZDateTime.from(now, location);
    return (
      start: tz.TZDateTime(
        location,
        localNow.year,
        localNow.month,
        localNow.day,
      ),
      end: tz.TZDateTime(
        location,
        localNow.year,
        localNow.month,
        localNow.day + 1,
      ),
    );
  }

  DateTime date(String text) {
    final value = parseDateOnly(text);
    return tz.TZDateTime(location, value.year, value.month, value.day);
  }
}

DateTime parseDateOnly(String text) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    throw const TodayException('invalid_date');
  }
  final value = DateTime.tryParse(text);
  if (value == null ||
      value.year < 1 ||
      value.toIso8601String().substring(0, 10) != text) {
    throw const TodayException('invalid_date');
  }
  return value;
}

DateTime parseTimestamp(String text) {
  final match = RegExp(
    r'^(\d{4}-\d{2}-\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:[Zz]|([+-])(\d{2}):?(\d{2}))$',
  ).firstMatch(text);
  if (match == null) {
    throw const TodayException('missing_timezone');
  }
  parseDateOnly(match[1]!);
  if (int.parse(match[2]!) > 23 ||
      int.parse(match[3]!) > 59 ||
      int.parse(match[4]!) > 59 ||
      int.parse(match[6] ?? '0') > 23 ||
      int.parse(match[7] ?? '0') > 59) {
    throw const TodayException('invalid_date');
  }
  final value = DateTime.tryParse(text);
  if (value == null) throw const TodayException('invalid_date');
  return value;
}
