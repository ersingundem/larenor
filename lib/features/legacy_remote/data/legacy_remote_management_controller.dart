import 'package:flutter/foundation.dart';

import '../domain/legacy_remote_models.dart';
import 'legacy_remote_management_api.dart';

enum LegacyRemoteManagementState {
  idle,
  loading,
  ready,
  awaitingConfirmation,
  busy,
  verified,
  failed,
  stale,
}

/// Executes only allowlisted opaque commands for one route/session authority.
final class LegacyRemoteManagementController extends ChangeNotifier {
  LegacyRemoteManagementController({
    required this.api,
    required this.authority,
    required this.isCurrent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LegacyRemoteManagementApi api;
  final LegacyRemoteAuthority authority;
  final bool Function() isCurrent;
  final DateTime Function() _clock;
  final List<LegacyRemoteDevice> _devices = [];
  int _epoch = 0;
  bool _interactive = true;
  bool _disposed = false;

  LegacyRemoteManagementState state = LegacyRemoteManagementState.idle;
  LegacyRemoteCommandPreview? pendingPreview;
  LegacyRemoteCommandResult? lastResult;
  List<LegacyRemoteDevice> get devices => List.unmodifiable(_devices);

  bool _current() {
    if (_disposed || !_interactive || !authority.isBounded) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool get canAct => _current() && state != LegacyRemoteManagementState.busy;
  bool _operationCurrent(int operation) => operation == _epoch && _current();

  void _stale() {
    _devices.clear();
    pendingPreview = null;
    lastResult = null;
    state = LegacyRemoteManagementState.stale;
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
    lastResult = null;
    state = LegacyRemoteManagementState.loading;
    notifyListeners();
    try {
      final response = await api.list(authority);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      final ids = response.map((item) => item.deviceId).toSet();
      if (response.length > 100 ||
          ids.length != response.length ||
          response.any(
            (item) => item.authority != authority || !item.isCoherent,
          )) {
        _devices.clear();
        state = LegacyRemoteManagementState.failed;
      } else {
        _devices
          ..clear()
          ..addAll(response);
        state = LegacyRemoteManagementState.ready;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      _devices.clear();
      state = LegacyRemoteManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> preview(
    LegacyRemoteDevice device,
    LegacyRemoteCommandDefinition command, {
    int repeats = 1,
    int holdMs = 0,
  }) async {
    if (!canAct ||
        (state != LegacyRemoteManagementState.ready &&
            state != LegacyRemoteManagementState.verified) ||
        !_devices.contains(device) ||
        !device.commands.contains(command) ||
        !device.canDispatch ||
        repeats < 1 ||
        repeats > command.maxRepeats ||
        holdMs < 0 ||
        holdMs > command.maxHoldMs) {
      return;
    }
    final operation = ++_epoch;
    pendingPreview = null;
    lastResult = null;
    state = LegacyRemoteManagementState.busy;
    notifyListeners();
    try {
      final value = await api.preview(
        authority,
        device: device,
        command: command,
        repeats: repeats,
        holdMs: holdMs,
      );
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!value.isExactFor(authority, device, command, _clock())) {
        state = LegacyRemoteManagementState.failed;
      } else {
        pendingPreview = value;
        state = LegacyRemoteManagementState.awaitingConfirmation;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      state = LegacyRemoteManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  void cancelPending() {
    if (!_current() || pendingPreview == null) return;
    _epoch++;
    pendingPreview = null;
    state = LegacyRemoteManagementState.ready;
    notifyListeners();
  }

  Future<void> confirmPending() async {
    final preview = pendingPreview;
    if (!_current() ||
        state != LegacyRemoteManagementState.awaitingConfirmation ||
        preview == null ||
        !preview.expiresAt.isAfter(_clock())) {
      return;
    }
    final operation = ++_epoch;
    state = LegacyRemoteManagementState.busy;
    notifyListeners();
    try {
      final result = await api.confirm(authority, preview);
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      if (!result.isExactFor(preview)) {
        pendingPreview = null;
        state = LegacyRemoteManagementState.failed;
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
        state = LegacyRemoteManagementState.failed;
      } else {
        pendingPreview = null;
        lastResult = readback;
        state = LegacyRemoteManagementState.verified;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) {
        _stale();
        return;
      }
      // A missing delivery acknowledgement is ambiguous: never replay it.
      pendingPreview = null;
      lastResult = null;
      state = LegacyRemoteManagementState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _devices.clear();
    pendingPreview = null;
    lastResult = null;
    super.dispose();
  }
}
