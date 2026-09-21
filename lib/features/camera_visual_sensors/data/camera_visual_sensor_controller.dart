import 'package:flutter/foundation.dart';

import '../domain/camera_visual_sensor_models.dart';

enum CameraVisualSensorFailure { unavailable, staleAuthority, invalidScope }

final class CameraVisualSensorController extends ChangeNotifier {
  factory CameraVisualSensorController({
    required CameraVisualSensorGateway gateway,
    required bool Function() isCurrent,
    required String coreId,
    required String homeId,
  }) => CameraVisualSensorController._(gateway, isCurrent, coreId, homeId);

  CameraVisualSensorController._(
    this._gateway,
    this._isCurrent,
    this._coreId,
    this._homeId,
  );

  final CameraVisualSensorGateway _gateway;
  final bool Function() _isCurrent;
  final String _coreId, _homeId;
  CameraVisualSensorSummary? _value;
  CameraVisualSensorFailure? _failure;
  bool _busy = false, _retired = false;
  int _epoch = 0;

  CameraVisualSensorSummary? get value => _value;
  CameraVisualSensorFailure? get failure => _failure;
  bool get busy => _busy;

  bool _current() {
    if (_retired) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    if (_busy || !_current()) return;
    final operation = ++_epoch;
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final next = await _gateway.load();
      if (operation != _epoch || !_current()) {
        if (!_retired) {
          _value = null;
          _failure = CameraVisualSensorFailure.staleAuthority;
        }
        return;
      }
      if (next.coreId != _coreId || next.homeId != _homeId) {
        _value = null;
        _failure = CameraVisualSensorFailure.invalidScope;
        return;
      }
      _value = CameraVisualSensorSummary(
        coreId: next.coreId,
        homeId: next.homeId,
        capability: next.capability,
        sensors: List.unmodifiable(next.sensors),
      );
    } catch (_) {
      if (operation == _epoch && _current()) {
        _value = null;
        _failure = CameraVisualSensorFailure.unavailable;
      }
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    _busy = false;
    _value = null;
    _gateway.retire();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
