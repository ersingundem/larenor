import '../domain/kiosk_sensor_models.dart';
import 'kiosk_sensor_api.dart';

final class KioskSensorController {
  KioskSensorController(this._api);
  final KioskSensorApi _api;
  KioskSensorSnapshot? _snapshot;
  int _generation = 0;
  bool _busy = false;

  bool get active => _snapshot?.sampling == true;
  KioskSensorSnapshot? get snapshot => _snapshot;

  Future<KioskSensorSnapshot> start({int intervalMillis = 1000}) async {
    if (active || _busy) {
      throw const KioskSensorException(KioskSensorFailure.busy);
    }
    final generation = ++_generation;
    _busy = true;
    try {
      final value = await _api.start(intervalMillis: intervalMillis);
      if (generation != _generation || !value.sampling || value.sequence != 0) {
        try {
          await _api.stop(value.sessionId);
        } catch (_) {
          // Native lifecycle retirement is authoritative.
        }
        throw const KioskSensorException(KioskSensorFailure.expired);
      }
      _snapshot = value;
      return value;
    } finally {
      _busy = false;
    }
  }

  Future<KioskSensorSnapshot> refresh() async {
    final previous = _snapshot;
    if (previous == null || !previous.sampling) {
      throw const KioskSensorException(KioskSensorFailure.expired);
    }
    final generation = _generation;
    final value = await _api.read(previous.sessionId);
    final current = _snapshot;
    if (generation != _generation ||
        current == null ||
        current.sessionId != previous.sessionId ||
        !value.sampling ||
        value.sequence < current.sequence ||
        value.observedAtElapsedMillis < current.observedAtElapsedMillis) {
      throw const KioskSensorException(KioskSensorFailure.expired);
    }
    if (value.sequence == current.sequence &&
        (value.lux != current.lux ||
            value.motionDelta != current.motionDelta ||
            value.lightAvailable != current.lightAvailable ||
            value.motionAvailable != current.motionAvailable ||
            value.approachAvailable != current.approachAvailable ||
            value.approachMaxRangeCm != current.approachMaxRangeCm ||
            value.cameraStatus != current.cameraStatus)) {
      throw const KioskSensorException(KioskSensorFailure.unavailable);
    }
    _snapshot = value;
    return value;
  }

  Future<void> stop() async {
    final previous = _snapshot;
    if (previous == null) return;
    final generation = ++_generation;
    _snapshot = null;
    _busy = true;
    try {
      final receipt = await _api.stop(previous.sessionId);
      if (generation != _generation ||
          receipt.sessionId != previous.sessionId ||
          !receipt.stopped) {
        throw const KioskSensorException(KioskSensorFailure.unavailable);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> retire() async {
    final previous = _snapshot;
    _generation++;
    _snapshot = null;
    if (previous == null) return;
    try {
      await _api.stop(previous.sessionId);
    } catch (_) {
      // Native lifecycle retirement is authoritative and no old session is reused.
    }
  }
}
