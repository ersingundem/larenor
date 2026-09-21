import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum KioskUsageEvent {
  rendererFailure,
  timeout,
  recoveryAttempt,
  recoveryBlocked,
  ready,
}

final class KioskUsageException implements Exception {
  const KioskUsageException();
  @override
  String toString() => 'Local kiosk usage unavailable';
}

abstract interface class KioskUsageStore {
  Future<String?> read();
  Future<void> write(String value);
}

final class SharedPreferencesKioskUsageStore implements KioskUsageStore {
  SharedPreferencesKioskUsageStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static const key = 'kiosk_usage_v1';
  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<String?> read() async => (await _preferences()).getString(key);

  @override
  Future<void> write(String value) async {
    if (!await (await _preferences()).setString(key, value)) {
      throw const KioskUsageException();
    }
  }
}

final class KioskUsageDay {
  const KioskUsageDay({
    required this.day,
    required this.rendererFailure,
    required this.timeout,
    required this.recoveryAttempt,
    required this.recoveryBlocked,
    required this.ready,
  });

  final DateTime day;
  final int rendererFailure, timeout, recoveryAttempt, recoveryBlocked, ready;

  int count(KioskUsageEvent event) => switch (event) {
    KioskUsageEvent.rendererFailure => rendererFailure,
    KioskUsageEvent.timeout => timeout,
    KioskUsageEvent.recoveryAttempt => recoveryAttempt,
    KioskUsageEvent.recoveryBlocked => recoveryBlocked,
    KioskUsageEvent.ready => ready,
  };

  KioskUsageDay increment(KioskUsageEvent event) => KioskUsageDay(
    day: day,
    rendererFailure: event == KioskUsageEvent.rendererFailure
        ? rendererFailure + 1
        : rendererFailure,
    timeout: event == KioskUsageEvent.timeout ? timeout + 1 : timeout,
    recoveryAttempt: event == KioskUsageEvent.recoveryAttempt
        ? recoveryAttempt + 1
        : recoveryAttempt,
    recoveryBlocked: event == KioskUsageEvent.recoveryBlocked
        ? recoveryBlocked + 1
        : recoveryBlocked,
    ready: event == KioskUsageEvent.ready ? ready + 1 : ready,
  );

  Map<String, Object> toJson() => {
    'day': _dayText(day),
    'rendererFailure': rendererFailure,
    'timeout': timeout,
    'recoveryAttempt': recoveryAttempt,
    'recoveryBlocked': recoveryBlocked,
    'ready': ready,
  };
}

final class KioskUsageSnapshot {
  KioskUsageSnapshot(List<KioskUsageDay> days) : days = List.unmodifiable(days);
  final List<KioskUsageDay> days;

  int count(KioskUsageEvent event) =>
      days.fold(0, (sum, day) => sum + day.count(event));
}

final class KioskUsageRepository {
  KioskUsageRepository({KioskUsageStore? store, DateTime Function()? now})
    : _store = store ?? SharedPreferencesKioskUsageStore(),
      _now = now ?? DateTime.now;

  final KioskUsageStore _store;
  final DateTime Function() _now;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() operation) async {
    final before = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await before;
    try {
      return await operation();
    } finally {
      done.complete();
    }
  }

  Future<KioskUsageSnapshot> read() => _serial(_readUnlocked);

  Future<void> record(KioskUsageEvent event) => _serial(() async {
    final current = await _readUnlocked();
    final today = _utcDay(_now());
    final days = [...current.days];
    final index = days.indexWhere((value) => value.day == today);
    if (index < 0) {
      days.add(
        KioskUsageDay(
          day: today,
          rendererFailure: event == KioskUsageEvent.rendererFailure ? 1 : 0,
          timeout: event == KioskUsageEvent.timeout ? 1 : 0,
          recoveryAttempt: event == KioskUsageEvent.recoveryAttempt ? 1 : 0,
          recoveryBlocked: event == KioskUsageEvent.recoveryBlocked ? 1 : 0,
          ready: event == KioskUsageEvent.ready ? 1 : 0,
        ),
      );
    } else {
      if (days[index].count(event) >= 999999) {
        throw const KioskUsageException();
      }
      days[index] = days[index].increment(event);
    }
    final retained = _retained(days, today);
    await _store.write(
      jsonEncode({
        'version': 1,
        'days': [for (final day in retained) day.toJson()],
      }),
    );
  });

  Future<String> csvPreview() => _serial(() async {
    final snapshot = await _readUnlocked();
    final rows = <String>[
      'day,renderer_failure,timeout,recovery_attempt,recovery_blocked,ready',
      for (final day in snapshot.days)
        '${_dayText(day.day)},${day.rendererFailure},${day.timeout},'
            '${day.recoveryAttempt},${day.recoveryBlocked},${day.ready}',
    ];
    return rows.join('\n');
  });

  Future<KioskUsageSnapshot> _readUnlocked() async {
    try {
      final raw = await _store.read();
      if (raw == null) return KioskUsageSnapshot(const []);
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic> ||
          json.length != 2 ||
          json['version'] != 1 ||
          json['days'] is! List ||
          (json['days'] as List).length > 30) {
        throw const KioskUsageException();
      }
      final days = <KioskUsageDay>[];
      final seen = <DateTime>{};
      for (final rawDay in json['days'] as List) {
        if (rawDay is! Map<String, dynamic> ||
            rawDay.length != 6 ||
            !const {
              'day',
              'rendererFailure',
              'timeout',
              'recoveryAttempt',
              'recoveryBlocked',
              'ready',
            }.containsAll(rawDay.keys)) {
          throw const KioskUsageException();
        }
        final day = _parseDay(rawDay['day']);
        final values = [
          rawDay['rendererFailure'],
          rawDay['timeout'],
          rawDay['recoveryAttempt'],
          rawDay['recoveryBlocked'],
          rawDay['ready'],
        ];
        if (day == null ||
            !seen.add(day) ||
            values.any(
              (value) => value is! int || value < 0 || value > 999999,
            )) {
          throw const KioskUsageException();
        }
        days.add(
          KioskUsageDay(
            day: day,
            rendererFailure: values[0] as int,
            timeout: values[1] as int,
            recoveryAttempt: values[2] as int,
            recoveryBlocked: values[3] as int,
            ready: values[4] as int,
          ),
        );
      }
      return KioskUsageSnapshot(_retained(days, _utcDay(_now())));
    } on KioskUsageException {
      rethrow;
    } catch (_) {
      throw const KioskUsageException();
    }
  }

  static List<KioskUsageDay> _retained(
    List<KioskUsageDay> days,
    DateTime today,
  ) {
    final first = today.subtract(const Duration(days: 29));
    return days
        .where((day) => !day.day.isBefore(first) && !day.day.isAfter(today))
        .toList()
      ..sort((a, b) => a.day.compareTo(b.day));
  }
}

DateTime _utcDay(DateTime value) =>
    DateTime.utc(value.toUtc().year, value.toUtc().month, value.toUtc().day);

String _dayText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

DateTime? _parseDay(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final parsed = DateTime.tryParse('${value}T00:00:00Z');
  return parsed != null && _dayText(parsed) == value ? parsed : null;
}
