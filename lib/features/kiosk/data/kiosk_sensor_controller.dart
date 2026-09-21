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
    if (generation != _generation ||
        _snapshot?.sessionId != previous.sessionId ||
        !value.sampling ||
        value.sequence < previous.sequence ||
        value.observedAtElapsedMillis < previous.observedAtElapsedMillis) {
      throw const KioskSensorException(KioskSensorFailure.expired);
    }
    if (value.sequence == previous.sequence &&
        (value.lux != previous.lux ||
            value.motionDelta != previous.motionDelta ||
            value.lightAvailable != previous.lightAvailable ||
            value.motionAvailable != previous.motionAvailable ||
            value.cameraStatus != previous.cameraStatus)) {
      throw const KioskSensorException(KioskSensorFailure.unavailable);
    }
    _snapshot = value;
    return value;
  }

  Future<void> stop() async {
    final previous = _snapshot;
    if (previous == null) return;
    final generation = _generation;
    final receipt = await _api.stop(previous.sessionId);
    if (generation != _generation ||
        receipt.sessionId != previous.sessionId ||
        !receipt.stopped) {
      throw const KioskSensorException(KioskSensorFailure.unavailable);
    }
    _generation++;
    _snapshot = null;
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
