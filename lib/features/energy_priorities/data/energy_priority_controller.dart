import 'package:flutter/foundation.dart';

import '../domain/energy_priority_models.dart';

abstract interface class EnergyPriorityApi {
  Future<EnergyPrioritySnapshot> load();
  Future<EnergyCommandPreview> preview(
    EnergyPrioritySnapshot value,
    EnergyPlanSlot slot,
  );
  Future<EnergyCommandResult> confirm(EnergyCommandPreview value);
  Future<EnergyCommandResult> readback(EnergyCommandPreview value);
}

enum EnergyPriorityViewState {
  idle,
  loading,
  ready,
  busy,
  awaitingConfirmation,
  verified,
  failed,
  stale,
}

final class EnergyPriorityController extends ChangeNotifier {
  EnergyPriorityController({required this.api, required this.isCurrent});
  final EnergyPriorityApi api;
  final bool Function() isCurrent;
  int _epoch = 0;
  bool _interactive = true, _disposed = false;
  EnergyPriorityViewState state = EnergyPriorityViewState.idle;
  EnergyPrioritySnapshot? snapshot;
  EnergyCommandPreview? pending;

  bool _current() {
    if (_disposed || !_interactive) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _operationCurrent(int value) => value == _epoch && _current();
  bool get canAct =>
      _current() &&
      snapshot?.canControl == true &&
      state != EnergyPriorityViewState.loading &&
      state != EnergyPriorityViewState.busy;

  void _stale() {
    snapshot = null;
    pending = null;
    state = EnergyPriorityViewState.stale;
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
    if (!_current()) return _stale();
    final operation = ++_epoch;
    pending = null;
    state = EnergyPriorityViewState.loading;
    notifyListeners();
    try {
      final value = await api.load();
      if (!_operationCurrent(operation)) return _stale();
      snapshot = value;
      state = EnergyPriorityViewState.ready;
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      snapshot = null;
      state = EnergyPriorityViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> preview(EnergyPlanSlot slot) async {
    final before = snapshot;
    if (!canAct || before == null || !before.slots.contains(slot)) return;
    final operation = ++_epoch;
    state = EnergyPriorityViewState.busy;
    notifyListeners();
    try {
      final value = await api.preview(before, slot);
      if (!_operationCurrent(operation)) return _stale();
      if (value.planId != before.planId ||
          value.inputDigest != before.inputDigest ||
          value.accountId != before.accountId ||
          value.sessionFamilyId != before.sessionFamilyId ||
          value.batteryId != before.batteryId ||
          value.batteryRevision != before.batteryRevision ||
          value.inverterId != before.inverterId ||
          value.inverterRevision != before.inverterRevision) {
        state = EnergyPriorityViewState.failed;
      } else {
        pending = value;
        state = EnergyPriorityViewState.awaitingConfirmation;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      state = EnergyPriorityViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> confirm() async {
    final value = pending;
    final before = snapshot;
    if (!canAct ||
        value == null ||
        before == null ||
        value.planId != before.planId) {
      return;
    }
    final operation = ++_epoch;
    state = EnergyPriorityViewState.busy;
    notifyListeners();
    try {
      final receipt = await api.confirm(value);
      if (!_operationCurrent(operation)) return _stale();
      if (!receipt.exactFor(value)) {
        state = EnergyPriorityViewState.failed;
      } else {
        final readback = await api.readback(value);
        if (!_operationCurrent(operation)) return _stale();
        if (!readback.exactFor(value) || readback != receipt) {
          state = EnergyPriorityViewState.failed;
        } else {
          state = EnergyPriorityViewState.verified;
        }
      }
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      state = EnergyPriorityViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  void cancelPreview() {
    if (!_current()) return _stale();
    pending = null;
    state = EnergyPriorityViewState.ready;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    snapshot = null;
    pending = null;
    super.dispose();
  }
}
