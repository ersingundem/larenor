import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/mesh_center_models.dart';
import 'mesh_center_management_api.dart';

enum MeshCenterManagementState {
  idle,
  loading,
  ready,
  awaitingConfirmation,
  busy,
  verified,
  failed,
  stale,
}

final class MeshCenterManagementController extends ChangeNotifier {
  MeshCenterManagementController({
    required this.api,
    required this.authority,
    required this.isCurrent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MeshCenterManagementApi api;
  final MeshClientAuthority authority;
  final bool Function() isCurrent;
  final DateTime Function() _clock;
  int _epoch = 0;
  bool _interactive = true;
  bool _disposed = false;

  MeshCenterManagementState state = MeshCenterManagementState.idle;
  MeshCenterSnapshot? snapshot;
  MeshFirmwareUpdatePreview? pendingPreview;
  MeshFirmwareUpdateResult? lastResult;
  MeshManagedOtaPreview? pendingManagedPreview;
  MeshManagedOtaResult? lastManagedResult;

  bool _current() {
    if (_disposed || !_interactive || !authority.isBounded) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _operationCurrent(int operation) => operation == _epoch && _current();
  bool get canAct => _current() && state != MeshCenterManagementState.busy;
  bool canUpdateDevice(MeshClientDevice device) =>
      canAct &&
      authority.admin &&
      authority.canUpdate &&
      snapshot?.devices.contains(device) == true &&
      device.canOfferUpdateAt(_clock());

  bool canCheckManagedUpdate(MeshClientDevice device) {
    final now = _clock();
    return canAct &&
        api is ManagedOtaManagementApi &&
        authority.admin &&
        authority.canUpdate &&
        snapshot?.devices.contains(device) == true &&
        device.protocol == MeshProtocol.zigbee &&
        device.reachable &&
        !device.updating &&
        device.lastSeenAt != null &&
        !device.lastSeenAt!.isAfter(now) &&
        now.difference(device.lastSeenAt!) <= const Duration(minutes: 5) &&
        (device.powerSource == MeshPowerSource.mains ||
            device.batteryPercent != null && device.batteryPercent! >= 70);
  }

  void _stale() {
    snapshot = null;
    pendingPreview = null;
    lastResult = null;
    pendingManagedPreview = null;
    lastManagedResult = null;
    state = MeshCenterManagementState.stale;
    if (!_disposed) notifyListeners();
  }

  void setInteractive(bool value) {
    if (_disposed || value == _interactive) return;
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
    snapshot = null;
    pendingPreview = null;
    lastResult = null;
    pendingManagedPreview = null;
    lastManagedResult = null;
    state = MeshCenterManagementState.loading;
    notifyListeners();
    try {
      final response = await api.load(authority);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (response.authority != authority || !response.isCoherentAt(_clock())) {
        state = MeshCenterManagementState.failed;
      } else {
        snapshot = response;
        state = MeshCenterManagementState.ready;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> previewUpdate(MeshClientDevice device) async {
    final currentSnapshot = snapshot;
    final offer = device.update;
    if (!canUpdateDevice(device) ||
        (state != MeshCenterManagementState.ready &&
            state != MeshCenterManagementState.verified) ||
        currentSnapshot == null ||
        !currentSnapshot.devices.contains(device) ||
        offer == null) {
      return;
    }
    final operation = ++_epoch;
    pendingPreview = null;
    lastResult = null;
    state = MeshCenterManagementState.busy;
    notifyListeners();
    try {
      final value = await api.preview(
        authority,
        snapshot: currentSnapshot,
        device: device,
        firmware: offer,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!value.isExactFor(
        authority,
        currentSnapshot,
        device,
        offer,
        _clock(),
      )) {
        state = MeshCenterManagementState.failed;
      } else {
        pendingPreview = value;
        state = MeshCenterManagementState.awaitingConfirmation;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> previewManagedUpdate(MeshClientDevice device) async {
    final currentSnapshot = snapshot;
    if (api is! ManagedOtaManagementApi ||
        !canCheckManagedUpdate(device) ||
        (state != MeshCenterManagementState.ready &&
            state != MeshCenterManagementState.verified) ||
        currentSnapshot == null ||
        !currentSnapshot.devices.contains(device)) {
      return;
    }
    final managed = api as ManagedOtaManagementApi;
    final operation = ++_epoch;
    pendingPreview = null;
    pendingManagedPreview = null;
    lastResult = null;
    lastManagedResult = null;
    state = MeshCenterManagementState.busy;
    notifyListeners();
    try {
      final availability = await managed.checkManagedOta(
        authority,
        snapshot: currentSnapshot,
        device: device,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (availability.snapshot.authority != authority ||
          !availability.offer.isExactFor(
            availability.snapshot,
            availability.device,
            _clock(),
          )) {
        state = MeshCenterManagementState.failed;
      } else {
        final preview = await managed.previewManagedOta(
          authority,
          availability,
        );
        if (!_operationCurrent(operation)) {
          _stale();
          return;
        }
        if (!preview.isExactFor(availability, _clock())) {
          state = MeshCenterManagementState.failed;
        } else {
          snapshot = availability.snapshot;
          pendingManagedPreview = preview;
          state = MeshCenterManagementState.awaitingConfirmation;
        }
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  void cancelPending() {
    if (!_current() ||
        (pendingPreview == null && pendingManagedPreview == null)) {
      return;
    }
    _epoch++;
    pendingPreview = null;
    pendingManagedPreview = null;
    state = MeshCenterManagementState.ready;
    notifyListeners();
  }

  Future<void> confirmPending() async {
    final managedPreview = pendingManagedPreview;
    if (managedPreview != null) {
      await _confirmManagedPending(managedPreview);
      return;
    }
    final preview = pendingPreview;
    if (!_current() ||
        state != MeshCenterManagementState.awaitingConfirmation ||
        preview == null ||
        !preview.expiresAt.isAfter(_clock())) {
      return;
    }
    final operation = ++_epoch;
    state = MeshCenterManagementState.busy;
    notifyListeners();
    try {
      final receipt = await api.confirm(authority, preview);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!receipt.isExactFor(preview)) {
        pendingPreview = null;
        state = MeshCenterManagementState.failed;
        notifyListeners();
        return;
      }
      final readback = await api.readback(
        authority,
        requestId: preview.requestId,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!readback.isExactFor(preview)) {
        pendingPreview = null;
        state = MeshCenterManagementState.failed;
      } else {
        pendingPreview = null;
        lastResult = readback;
        state = MeshCenterManagementState.verified;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      // Delivery is ambiguous. Never repeat a firmware command automatically.
      pendingPreview = null;
      lastResult = null;
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _confirmManagedPending(MeshManagedOtaPreview preview) async {
    if (api is! ManagedOtaManagementApi ||
        !_current() ||
        state != MeshCenterManagementState.awaitingConfirmation ||
        !preview.expiresAt.isAfter(_clock())) {
      return;
    }
    final managed = api as ManagedOtaManagementApi;
    final operation = ++_epoch;
    state = MeshCenterManagementState.busy;
    notifyListeners();
    try {
      MeshManagedOtaResult? receipt;
      try {
        receipt = await managed.confirmManagedOta(authority, preview);
      } on LarenorServerException catch (error) {
        // The POST may have reached Core before the 20-second HTTP boundary.
        // Only read the durable record; never send confirm again.
        if (error.code != 'timeout' &&
            error.code != 'connection_failed' &&
            error.code != 'invalid_response') {
          rethrow;
        }
      }
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (receipt != null &&
          receipt.status == MeshUpdateStatus.confirmed &&
          !receipt.isExactFor(preview)) {
        pendingManagedPreview = null;
        lastManagedResult = receipt;
        state = MeshCenterManagementState.failed;
        notifyListeners();
        return;
      }
      final readback = await managed.awaitManagedOtaResult(
        authority,
        requestId: preview.requestId,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      pendingManagedPreview = null;
      lastManagedResult = readback;
      state = readback.isExactFor(preview)
          ? MeshCenterManagementState.verified
          : MeshCenterManagementState.failed;
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      // The persisted dispatch may have reached Zigbee2MQTT. Never auto-retry.
      pendingManagedPreview = null;
      lastManagedResult = null;
      state = MeshCenterManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    snapshot = null;
    pendingPreview = null;
    lastResult = null;
    pendingManagedPreview = null;
    lastManagedResult = null;
    super.dispose();
  }
}
