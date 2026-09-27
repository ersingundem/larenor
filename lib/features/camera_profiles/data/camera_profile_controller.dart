import 'package:flutter/foundation.dart';

import '../domain/camera_profile_models.dart';
import 'camera_profile_api.dart';

enum CameraProfileViewState {
  idle,
  loading,
  ready,
  applying,
  rollingBack,
  verified,
  restored,
  partial,
  failed,
  stale,
}

final class CameraProfileController extends ChangeNotifier {
  CameraProfileController({required this.api, required this.isCurrent});
  final CameraProfileApi api;
  final bool Function() isCurrent;
  int _epoch = 0;
  bool _interactive = true;
  bool _disposed = false;
  CameraProfileViewState state = CameraProfileViewState.idle;
  CameraProfileSnapshot? snapshot;
  CameraApplyReceipt? receipt;
  CameraRollbackReceipt? rollbackReceipt;

  bool _current() {
    try {
      return !_disposed && _interactive && isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool get canApply =>
      _current() &&
      snapshot?.authority.canManage == true &&
      state != CameraProfileViewState.applying &&
      state != CameraProfileViewState.rollingBack;

  bool get canRollback =>
      _current() &&
      api is CameraProfileRollbackApi &&
      snapshot?.authority.canManage == true &&
      receipt?.canRollback == true &&
      rollbackReceipt == null &&
      state != CameraProfileViewState.applying &&
      state != CameraProfileViewState.rollingBack;

  void _stale() {
    snapshot = null;
    receipt = null;
    rollbackReceipt = null;
    state = CameraProfileViewState.stale;
    if (!_disposed) notifyListeners();
  }

  void setInteractive(bool value) {
    if (_disposed || value == _interactive) return;
    _interactive = value;
    if (!value) {
      _epoch++;
      api.retire();
      _stale();
    }
  }

  Future<void> load() async {
    if (!_current()) {
      _stale();
      return;
    }
    final operation = ++_epoch;
    state = CameraProfileViewState.loading;
    snapshot = null;
    receipt = null;
    rollbackReceipt = null;
    notifyListeners();
    try {
      final value = await api.bootstrap();
      if (operation != _epoch || !_current()) {
        _stale();
        return;
      }
      if (!value.authority.isBounded || !value.makesNoHardwarePrivacyClaim) {
        state = CameraProfileViewState.failed;
      } else {
        snapshot = value;
        state = CameraProfileViewState.ready;
      }
    } catch (_) {
      if (operation != _epoch || !_current()) {
        _stale();
        return;
      }
      state = CameraProfileViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> rollback() async {
    final value = snapshot;
    final applied = receipt;
    final rollbackApi = api is CameraProfileRollbackApi
        ? api as CameraProfileRollbackApi
        : null;
    if (!canRollback ||
        value == null ||
        applied == null ||
        rollbackApi == null) {
      return;
    }
    final operation = ++_epoch;
    state = CameraProfileViewState.rollingBack;
    notifyListeners();
    try {
      final result = await rollbackApi.rollback(value, applied);
      if (operation != _epoch || !_current()) {
        _stale();
        return;
      }
      rollbackReceipt = result;
      state = switch (result.status) {
        'restored' || 'already_original' => CameraProfileViewState.restored,
        'partial' => CameraProfileViewState.partial,
        _ => CameraProfileViewState.failed,
      };
    } catch (_) {
      if (operation != _epoch || !_current()) {
        _stale();
        return;
      }
      state = CameraProfileViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> apply() async {
    final value = snapshot;
    if (!canApply || value == null) return;
    final operation = ++_epoch;
    state = CameraProfileViewState.applying;
    receipt = null;
    rollbackReceipt = null;
    notifyListeners();
    try {
      final result = await api.apply(value);
      if (operation != _epoch || !_current()) {
        _stale();
        return;
      }
      receipt = result;
      state = switch (result.status) {
        'applied' || 'already_applied' => CameraProfileViewState.verified,
        'partial' => CameraProfileViewState.partial,
        _ => CameraProfileViewState.failed,
      };
    } catch (_) {
      if (operation != _epoch || !_current()) {
        _stale();
        return;
      }
      state = CameraProfileViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    api.retire();
    super.dispose();
  }
}
