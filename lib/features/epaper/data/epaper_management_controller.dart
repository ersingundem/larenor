import 'package:flutter/foundation.dart';

import '../domain/epaper_management_models.dart';
import 'epaper_management_api.dart';

enum EpaperManagementState {
  idle,
  loading,
  ready,
  awaitingConfirmation,
  busy,
  pendingDelivery,
  verified,
  failed,
  stale,
}

/// Owns one visible account/session-bound management interaction.
///
/// Lost or late command results are deliberately not replayed. A command is
/// successful only after an exact Core receipt and a fresh device readback.
final class EpaperManagementController extends ChangeNotifier {
  EpaperManagementController({
    required this.api,
    required this.authority,
    required this.isCurrent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final EpaperManagementApi api;
  final EpaperClientAuthority authority;
  final bool Function() isCurrent;
  final DateTime Function() _clock;
  final List<EpaperDeviceStatus> _devices = [];
  int _epoch = 0;
  bool _disposed = false;
  bool _interactive = true;

  EpaperManagementState state = EpaperManagementState.idle;
  EpaperCommandPreview? pendingPreview;

  List<EpaperDeviceStatus> get devices => List.unmodifiable(_devices);
  bool get canAct =>
      _current() && authority.canManage && state != EpaperManagementState.busy;

  bool _current() {
    if (_disposed || !_interactive || !authority.isBounded) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _operationCurrent(int operation) => operation == _epoch && _current();

  void _stale() {
    _devices.clear();
    pendingPreview = null;
    state = EpaperManagementState.stale;
    if (!_disposed) notifyListeners();
  }

  void setInteractive(bool value) {
    if (_interactive == value || _disposed) return;
    _interactive = value;
    if (!value) {
      _epoch++;
      _stale();
    }
  }

  Future<void> load() async {
    if (!_current()) {
      _stale();
      return;
    }
    final operation = ++_epoch;
    pendingPreview = null;
    state = EpaperManagementState.loading;
    notifyListeners();
    try {
      final response = await api.list(authority);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      final now = _clock();
      final deviceIds = response.map((device) => device.deviceId).toSet();
      if (response.length > 100 ||
          deviceIds.length != response.length ||
          response.any(
            (device) =>
                device.authority != authority || !device.isCoherentAt(now),
          )) {
        _devices.clear();
        state = EpaperManagementState.failed;
      } else {
        _devices
          ..clear()
          ..addAll(response);
        state = EpaperManagementState.ready;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      _devices.clear();
      state = EpaperManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> preview(
    EpaperDeviceStatus device,
    EpaperManagementAction action,
  ) async {
    if (!canAct ||
        !_devices.contains(device) ||
        !device.stored ||
        !device.reachable) {
      return;
    }
    final operation = ++_epoch;
    state = EpaperManagementState.busy;
    pendingPreview = null;
    notifyListeners();
    try {
      final value = await api.preview(
        authority,
        deviceId: device.deviceId,
        expectedDeviceRevision: device.deviceRevision,
        action: action,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!value.isExactFor(authority, device, action, _clock())) {
        state = EpaperManagementState.failed;
      } else {
        pendingPreview = value;
        state = EpaperManagementState.awaitingConfirmation;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = EpaperManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> map(EpaperDeviceMappingDraft draft) async {
    if (!canAct || !draft.isValid) return;
    final operation = ++_epoch;
    pendingPreview = null;
    state = EpaperManagementState.busy;
    notifyListeners();
    try {
      final value = await api.map(authority, draft);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (value.authority != authority || !value.isCoherentAt(_clock())) {
        state = EpaperManagementState.failed;
      } else {
        _devices.removeWhere((item) => item.deviceId == value.deviceId);
        _devices.add(value);
        state = EpaperManagementState.ready;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = EpaperManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> cancelPending() async {
    if (!_current() || pendingPreview == null) return;
    final preview = pendingPreview!;
    final operation = ++_epoch;
    pendingPreview = null;
    state = EpaperManagementState.busy;
    notifyListeners();
    try {
      await api.cancel(authority, preview);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = EpaperManagementState.ready;
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = EpaperManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> confirmPending() async {
    final preview = pendingPreview;
    if (!canAct || preview == null || !preview.expiresAt.isAfter(_clock())) {
      return;
    }
    final operation = ++_epoch;
    state = EpaperManagementState.busy;
    notifyListeners();
    try {
      final receipt = await api.confirm(authority, preview);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      final receiptBound =
          receipt.authority == preview.authority &&
          receipt.requestId == preview.requestId &&
          receipt.deviceId == preview.deviceId &&
          receipt.deviceRevision == preview.deviceRevision &&
          receipt.action == preview.action;
      if (!receiptBound || receipt.status == EpaperCommandStatus.rejected) {
        pendingPreview = null;
        state = EpaperManagementState.failed;
        notifyListeners();
        return;
      }
      final readback = await api.readback(
        authority,
        deviceId: preview.deviceId,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      final exact =
          readback.authority == authority &&
          readback.deviceId == preview.deviceId &&
          readback.deviceRevision == preview.deviceRevision &&
          readback.layoutRevision == preview.expectedLayoutRevision &&
          readback.snapshotTrust == EpaperSnapshotTrust.verified &&
          readback.snapshotDigest == receipt.observedSnapshotDigest &&
          readback.verifiedDigest == receipt.observedSnapshotDigest &&
          readback.isCoherentAt(_clock());
      final pending =
          receipt.status == EpaperCommandStatus.uncertain &&
          readback.authority == authority &&
          readback.deviceId == preview.deviceId &&
          readback.deviceRevision == preview.deviceRevision &&
          readback.layoutRevision == preview.expectedLayoutRevision &&
          const {
            EpaperSnapshotTrust.pending,
            EpaperSnapshotTrust.partial,
          }.contains(readback.snapshotTrust) &&
          readback.isCoherentAt(_clock());
      if (!exact && !pending) {
        pendingPreview = null;
        state = EpaperManagementState.failed;
      } else {
        final index = _devices.indexWhere(
          (item) => item.deviceId == readback.deviceId,
        );
        if (index < 0) {
          _devices.clear();
          state = EpaperManagementState.failed;
        } else {
          _devices[index] = readback;
          pendingPreview = null;
          state = exact
              ? EpaperManagementState.verified
              : EpaperManagementState.pendingDelivery;
        }
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      // A missing acknowledgement is ambiguous. Never replay automatically.
      pendingPreview = null;
      state = EpaperManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _devices.clear();
    pendingPreview = null;
    super.dispose();
  }
}
