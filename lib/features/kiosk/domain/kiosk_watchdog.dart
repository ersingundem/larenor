import '../data/kiosk_usage_repository.dart';

/// A synchronous decision gate around explicitly requested renderer recovery.
/// It has no timer and therefore cannot reconnect or replay by itself.
final class KioskRecoveryGate {
  KioskRecoveryGate({
    KioskUsageRepository? repository,
    DateTime Function()? now,
  }) : _repository = repository ?? KioskUsageRepository(),
       _now = now ?? DateTime.now;

  final KioskUsageRepository _repository;
  final DateTime Function() _now;
  final List<DateTime> _attempts = [];
  bool maintenanceRequired = false;

  bool get pendingAutomaticRecovery => false;

  Future<bool> allowExplicitRecovery() async {
    final now = _now().toUtc();
    _attempts.removeWhere(
      (attempt) => now.difference(attempt) >= const Duration(minutes: 10),
    );
    if (_attempts.length >= 3) {
      maintenanceRequired = true;
      await _repository.record(KioskUsageEvent.recoveryBlocked);
      return false;
    }
    _attempts.add(now);
    maintenanceRequired = false;
    await _repository.record(KioskUsageEvent.recoveryAttempt);
    return true;
  }

  Future<void> recordRendererFailure({required bool timeout}) =>
      _repository.record(
        timeout ? KioskUsageEvent.timeout : KioskUsageEvent.rendererFailure,
      );

  Future<void> recordReady() => _repository.record(KioskUsageEvent.ready);
}
