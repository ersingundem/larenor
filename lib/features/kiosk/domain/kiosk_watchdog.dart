import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/kiosk_usage_repository.dart';

/// Operational throttle state, kept separate from the aggregate usage export.
abstract interface class KioskRecoveryAttemptStore {
  Future<String?> read();
  Future<void> write(String value);
}

final class SharedPreferencesKioskRecoveryAttemptStore
    implements KioskRecoveryAttemptStore {
  static const key = 'kiosk_recovery_attempts_v1';

  @override
  Future<String?> read() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    return preferences.getString(key);
  }

  @override
  Future<void> write(String value) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(key, value)) {
      throw const KioskUsageException();
    }
  }
}

/// A synchronous decision gate around explicitly requested renderer recovery.
/// It has no timer and therefore cannot reconnect or replay by itself.
final class KioskRecoveryGate {
  KioskRecoveryGate({
    KioskUsageRepository? repository,
    KioskRecoveryAttemptStore? attemptStore,
    DateTime Function()? now,
  }) : _repository = repository ?? KioskUsageRepository(),
       _attemptStore =
           attemptStore ?? SharedPreferencesKioskRecoveryAttemptStore(),
       _now = now ?? DateTime.now;

  final KioskUsageRepository _repository;
  final KioskRecoveryAttemptStore _attemptStore;
  final DateTime Function() _now;
  // Gates can be recreated by navigation or a process restart. Serialize all
  // owners before the shared read/write so concurrent taps cannot exceed 3.
  static Future<void>? _tail;
  bool maintenanceRequired = false;

  bool get pendingAutomaticRecovery => false;

  Future<bool> allowExplicitRecovery() => _serial(() async {
    final now = _now().toUtc().millisecondsSinceEpoch;
    try {
      final attempts = await _recentAttempts(now);
      if (attempts.length >= 3) {
        maintenanceRequired = true;
        await _repository.record(KioskUsageEvent.recoveryBlocked);
        return false;
      }
      // Durably consume the attempt before granting any recovery. A failed
      // usage write may deny one attempt, but can never grant an extra one.
      await _attemptStore.write(
        jsonEncode({
          'version': 1,
          'attempts': [...attempts, now],
        }),
      );
      await _repository.record(KioskUsageEvent.recoveryAttempt);
      maintenanceRequired = false;
      return true;
    } catch (_) {
      maintenanceRequired = true;
      return false;
    }
  });

  Future<List<int>> _recentAttempts(int now) async {
    final raw = await _attemptStore.read();
    if (raw == null) return [];
    if (raw.length > 256) throw const KioskUsageException();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 2 ||
        decoded['version'] != 1 ||
        decoded['attempts'] is! List ||
        (decoded['attempts'] as List).length > 3) {
      throw const KioskUsageException();
    }
    final values = decoded['attempts'] as List;
    if (values.any((value) => value is! int || value < 0 || value > now)) {
      throw const KioskUsageException();
    }
    return values
        .cast<int>()
        .where(
          (value) => now - value < const Duration(minutes: 10).inMilliseconds,
        )
        .toList();
  }

  static Future<T> _serial<T>(Future<T> Function() operation) async {
    final before = _tail;
    final done = Completer<void>();
    final completion = done.future;
    _tail = completion;
    try {
      if (before != null) await before;
      return await operation();
    } finally {
      done.complete();
      if (identical(_tail, completion)) _tail = null;
    }
  }

  Future<void> recordRendererFailure({required bool timeout}) =>
      _repository.record(
        timeout ? KioskUsageEvent.timeout : KioskUsageEvent.rendererFailure,
      );

  Future<void> recordReady() => _repository.record(KioskUsageEvent.ready);
}
