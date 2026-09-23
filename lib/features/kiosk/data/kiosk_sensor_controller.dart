import '../domain/kiosk_sensor_models.dart';
import 'kiosk_sensor_api.dart';

enum _SensorMutation { none, start, stop, retire }

final class KioskSensorController {
  KioskSensorController(this._api);
  final KioskSensorApi _api;
  KioskSensorSnapshot? _snapshot;
  int _generation = 0;
  bool _readBusy = false;
  _SensorMutation _mutation = _SensorMutation.none;

  bool get active => _snapshot?.sampling == true;
  KioskSensorSnapshot? get snapshot => _snapshot;

  Future<KioskSensorSnapshot> start({int intervalMillis = 1000}) async {
    if (active || _readBusy || _mutation != _SensorMutation.none) {
      throw const KioskSensorException(KioskSensorFailure.busy);
    }
    final generation = ++_generation;
    _mutation = _SensorMutation.start;
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
      if (value.powerLimited) {
        await _stopPowerLimited(value.sessionId);
      }
      _snapshot = value;
      return value;
    } finally {
      if (_mutation == _SensorMutation.start) {
        _mutation = _SensorMutation.none;
      }
    }
  }

  Future<KioskSensorSnapshot> refresh() async {
    final previous = _snapshot;
    if (previous == null || !previous.sampling) {
      throw const KioskSensorException(KioskSensorFailure.expired);
    }
    if (_readBusy || _mutation != _SensorMutation.none) {
      throw const KioskSensorException(KioskSensorFailure.busy);
    }
    final generation = _generation;
    _readBusy = true;
    try {
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
          (value.observedAtElapsedMillis != current.observedAtElapsedMillis ||
              value.lux != current.lux ||
              value.motionDelta != current.motionDelta ||
              value.approachDistanceCm != current.approachDistanceCm ||
              value.lightAvailable != current.lightAvailable ||
              value.motionAvailable != current.motionAvailable ||
              value.approachAvailable != current.approachAvailable ||
              value.approachMaxRangeCm != current.approachMaxRangeCm ||
              value.cameraStatus != current.cameraStatus ||
              value.batteryPercent != current.batteryPercent ||
              value.thermalStatus != current.thermalStatus)) {
        throw const KioskSensorException(KioskSensorFailure.unavailable);
      }
      if (value.powerLimited) {
        _generation++;
        _snapshot = null;
        await _stopPowerLimited(value.sessionId);
      }
      _snapshot = value;
      return value;
    } finally {
      _readBusy = false;
    }
  }

  Future<Never> _stopPowerLimited(String sessionId) async {
    try {
      final receipt = await _api.stop(sessionId);
      if (receipt.sessionId != sessionId || !receipt.stopped) {
        throw const KioskSensorException(KioskSensorFailure.unavailable);
      }
    } on KioskSensorException catch (error) {
      if (error.failure == KioskSensorFailure.unavailable) rethrow;
      throw const KioskSensorException(KioskSensorFailure.unavailable);
    } catch (_) {
      throw const KioskSensorException(KioskSensorFailure.unavailable);
    }
    throw const KioskSensorException(KioskSensorFailure.powerLimited);
  }

  Future<void> stop() async {
    final previous = _snapshot;
    if (previous == null) return;
    final generation = ++_generation;
    _snapshot = null;
    _mutation = _SensorMutation.stop;
    try {
      final receipt = await _api.stop(previous.sessionId);
      if (generation != _generation ||
          receipt.sessionId != previous.sessionId ||
          !receipt.stopped) {
        throw const KioskSensorException(KioskSensorFailure.unavailable);
      }
    } finally {
      if (_mutation == _SensorMutation.stop) {
        _mutation = _SensorMutation.none;
      }
    }
  }

  Future<void> retire() async {
    final previous = _snapshot;
    if (_mutation == _SensorMutation.start) {
      _generation++;
      _snapshot = null;
      return;
    }
    if (_mutation != _SensorMutation.none) return;
    _generation++;
    _snapshot = null;
    if (previous == null) return;
    _mutation = _SensorMutation.retire;
    try {
      await _api.stop(previous.sessionId);
    } catch (_) {
      // Native lifecycle retirement is authoritative and no old session is reused.
    } finally {
      if (_mutation == _SensorMutation.retire) {
        _mutation = _SensorMutation.none;
      }
    }
  }
}
