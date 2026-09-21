import 'package:flutter/foundation.dart';

import '../domain/room_presence_management_models.dart';
import 'room_presence_management_api.dart';

enum RoomPresenceManagementState {
  idle,
  loading,
  ready,
  awaitingConfirmation,
  busy,
  verified,
  failed,
  stale,
}

/// One route- and session-owned view of privacy-reduced presence evidence.
final class RoomPresenceManagementController extends ChangeNotifier {
  RoomPresenceManagementController({
    required this.api,
    required this.authority,
    required this.isCurrent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RoomPresenceManagementApi api;
  final RoomPresenceClientAuthority authority;
  final bool Function() isCurrent;
  final DateTime Function() _clock;
  final List<RoomPresenceEvidence> _evidence = [];
  int _epoch = 0;
  bool _interactive = true;
  bool _disposed = false;

  RoomPresenceManagementState state = RoomPresenceManagementState.idle;
  PresenceCalibrationPreview? pendingPreview;
  List<RoomPresenceEvidence> get evidence => List.unmodifiable(_evidence);
  bool get canAct => _current() && state != RoomPresenceManagementState.busy;

  bool _current() {
    if (_disposed || !_interactive || !authority.isBounded) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _operationCurrent(int operation) => operation == _epoch && _current();

  void _stale([int? operation]) {
    if (operation != null && operation != _epoch) return;
    _evidence.clear();
    pendingPreview = null;
    state = RoomPresenceManagementState.stale;
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
    pendingPreview = null;
    state = RoomPresenceManagementState.loading;
    notifyListeners();
    try {
      final response = await api.list(authority);
      if (!_operationCurrent(operation)) {
        _stale(operation);
        return;
      }
      final ids = response.map((item) => item.deviceId).toSet();
      if (response.length > 100 ||
          ids.length != response.length ||
          response.any(
            (item) =>
                item.authority != authority || !item.isCoherentAt(_clock()),
          )) {
        _evidence.clear();
        state = RoomPresenceManagementState.failed;
      } else {
        _evidence
          ..clear()
          ..addAll(response);
        state = RoomPresenceManagementState.ready;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale(operation);
        return;
      }
      _evidence.clear();
      state = RoomPresenceManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> previewCalibration(RoomPresenceEvidence evidence) async {
    if (!canAct ||
        (state != RoomPresenceManagementState.ready &&
            state != RoomPresenceManagementState.verified) ||
        !_evidence.contains(evidence) ||
        !evidence.stored ||
        !evidence.providerReachable ||
        !evidence.consentActive) {
      return;
    }
    final operation = ++_epoch;
    state = RoomPresenceManagementState.busy;
    pendingPreview = null;
    notifyListeners();
    try {
      final value = await api.previewCalibration(
        authority,
        deviceId: evidence.deviceId,
        expectedDeviceRevision: evidence.deviceRevision,
        expectedModelRevision: evidence.modelRevision,
        roomId: evidence.configuredRoomId,
        expectedRoomRevision: evidence.configuredRoomRevision,
        expectedPolicyRevision: evidence.policyRevision,
        expectedConsentRevision: evidence.consentRevision,
        expectedCalibrationRevision: evidence.calibrationRevision,
      );
      if (!_operationCurrent(operation)) {
        _stale(operation);
        return;
      }
      if (!value.isExactFor(authority, evidence, _clock())) {
        state = RoomPresenceManagementState.failed;
      } else {
        pendingPreview = value;
        state = RoomPresenceManagementState.awaitingConfirmation;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale(operation);
        return;
      }
      state = RoomPresenceManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  void cancelPending() {
    if (!_current() || pendingPreview == null) return;
    _epoch++;
    pendingPreview = null;
    state = RoomPresenceManagementState.ready;
    notifyListeners();
  }

  Future<void> confirmPending() async {
    final preview = pendingPreview;
    if (!_current() ||
        state != RoomPresenceManagementState.awaitingConfirmation ||
        preview == null ||
        !preview.expiresAt.isAfter(_clock())) {
      return;
    }
    final operation = ++_epoch;
    state = RoomPresenceManagementState.busy;
    notifyListeners();
    try {
      final receipt = await api.confirmCalibration(authority, preview);
      if (!_operationCurrent(operation)) {
        _stale(operation);
        return;
      }
      if (!receipt.isExactFor(preview)) {
        pendingPreview = null;
        state = RoomPresenceManagementState.failed;
        notifyListeners();
        return;
      }
      final readback = await api.readback(
        authority,
        deviceId: preview.deviceId,
      );
      if (!_operationCurrent(operation)) {
        _stale(operation);
        return;
      }
      final exact =
          readback.authority == authority &&
          readback.deviceId == preview.deviceId &&
          readback.deviceRevision == preview.deviceRevision &&
          readback.modelRevision == preview.modelRevision &&
          readback.configuredRoomId == preview.roomId &&
          readback.configuredRoomRevision == preview.roomRevision &&
          readback.policyRevision == preview.policyRevision &&
          readback.consentRevision == preview.consentRevision &&
          readback.calibrationRevision == preview.nextCalibrationRevision &&
          readback.isCoherentAt(_clock());
      final index = _evidence.indexWhere(
        (item) => item.deviceId == readback.deviceId,
      );
      if (!exact || index < 0) {
        pendingPreview = null;
        state = RoomPresenceManagementState.failed;
      } else {
        _evidence[index] = readback;
        pendingPreview = null;
        state = RoomPresenceManagementState.verified;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale(operation);
        return;
      }
      // Missing confirmation is ambiguous and must never be replayed.
      pendingPreview = null;
      state = RoomPresenceManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _evidence.clear();
    pendingPreview = null;
    super.dispose();
  }
}
