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
  Future<EnergyReservePreview> previewReserve(EnergyPrioritySnapshot value);
  Future<EnergyReserveResult> confirmReserve(EnergyReservePreview value);
  Future<EnergyReserveResult> readbackReserve(EnergyReservePreview value);
}

abstract interface class EnergyReserveSetupApi {
  Future<List<EnergyReserveSource>> loadReserveSources(
    EnergyPrioritySnapshot snapshot,
  );
  Future<void> acceptReserveSource(
    EnergyPrioritySnapshot snapshot,
    EnergyReserveSource source,
    String entityId,
  );
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
  EnergyPriorityController({
    required this.api,
    required this.isCurrent,
    this.reserveSetupApi,
  });
  final EnergyPriorityApi api;
  final bool Function() isCurrent;
  final EnergyReserveSetupApi? reserveSetupApi;
  int _epoch = 0;
  bool _interactive = true, _disposed = false;
  EnergyPriorityViewState state = EnergyPriorityViewState.idle;
  EnergyPrioritySnapshot? snapshot;
  EnergyCommandPreview? pending;
  EnergyReservePreview? reservePending;
  List<EnergyReserveSource> reserveSources = const [];
  EnergyReserveSource? selectedReserveSource;
  bool reserveSetupBusy = false, reserveSetupNeedsRefresh = false;
  String? reserveSetupFailure;

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
  bool get canConfigureReserve => reserveSetupApi != null;

  void _stale() {
    snapshot = null;
    pending = null;
    reservePending = null;
    reserveSources = const [];
    selectedReserveSource = null;
    reserveSetupBusy = false;
    reserveSetupNeedsRefresh = false;
    reserveSetupFailure = null;
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
    reservePending = null;
    reserveSources = const [];
    selectedReserveSource = null;
    reserveSetupBusy = false;
    reserveSetupNeedsRefresh = false;
    reserveSetupFailure = null;
    state = EnergyPriorityViewState.loading;
    notifyListeners();
    try {
      final value = await api.load();
      if (!_operationCurrent(operation)) return _stale();
      snapshot = value;
      state = EnergyPriorityViewState.ready;
      if (!_disposed) notifyListeners();
      await _loadReserveSources(operation, value);
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      snapshot = null;
      state = EnergyPriorityViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadReserveSources(
    int operation,
    EnergyPrioritySnapshot value,
  ) async {
    final setup = reserveSetupApi;
    if (setup == null || !value.canAdminister || value.canSetReserve) return;
    reserveSetupBusy = true;
    reserveSetupFailure = null;
    if (!_disposed) notifyListeners();
    try {
      final sources = await setup.loadReserveSources(value);
      if (!_operationCurrent(operation)) return _stale();
      reserveSources = sources;
      selectedReserveSource = sources.firstOrNull;
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      reserveSetupFailure = 'setup_failed';
    } finally {
      if (!_disposed && operation == _epoch) {
        reserveSetupBusy = false;
        notifyListeners();
      }
    }
  }

  void selectReserveSource(EnergyReserveSource source) {
    if (!_current() || !reserveSources.contains(source) || reserveSetupBusy) {
      return;
    }
    selectedReserveSource = source;
    reserveSetupFailure = null;
    notifyListeners();
  }

  Future<void> acceptReserveSource(String entityId) async {
    final setup = reserveSetupApi;
    final before = snapshot;
    final source = selectedReserveSource;
    if (setup == null ||
        before == null ||
        source == null ||
        !before.canAdminister ||
        reserveSetupBusy ||
        reserveSetupNeedsRefresh ||
        !RegExp(r'^number\.[a-z0-9_]{1,249}$').hasMatch(entityId)) {
      return;
    }
    final operation = ++_epoch;
    reserveSetupBusy = true;
    reserveSetupFailure = null;
    notifyListeners();
    try {
      await setup.acceptReserveSource(before, source, entityId);
      if (!_operationCurrent(operation)) return _stale();
      reserveSetupBusy = false;
      await load();
      return;
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      reserveSetupFailure = 'setup_failed';
      reserveSetupNeedsRefresh = true;
    }
    if (!_disposed) {
      reserveSetupBusy = false;
      notifyListeners();
    }
  }

  Future<void> preview(EnergyPlanSlot slot) async {
    final before = snapshot;
    if (!canAct ||
        before == null ||
        !before.slots.contains(slot) ||
        !before.supports(slot)) {
      return;
    }
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

  Future<void> previewReserve() async {
    final before = snapshot;
    if (!canAct || before == null || !before.canSetReserve) return;
    final operation = ++_epoch;
    state = EnergyPriorityViewState.busy;
    notifyListeners();
    try {
      final value = await api.previewReserve(before);
      if (!_operationCurrent(operation)) return _stale();
      if (value.inputDigest != before.inputDigest ||
          value.accountId != before.accountId ||
          value.sessionFamilyId != before.sessionFamilyId ||
          value.batteryId != before.batteryId ||
          value.batteryRevision != before.batteryRevision ||
          value.batteryProviderRevision != before.batteryProviderRevision ||
          value.inverterId != before.inverterId ||
          value.inverterRevision != before.inverterRevision ||
          value.targetReservePercent != before.reservePercent) {
        state = EnergyPriorityViewState.failed;
      } else {
        reservePending = value;
        state = EnergyPriorityViewState.awaitingConfirmation;
      }
    } catch (_) {
      if (!_operationCurrent(operation)) return _stale();
      state = EnergyPriorityViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> confirmReserve() async {
    final value = reservePending;
    final before = snapshot;
    if (!canAct || value == null || before == null || !before.canSetReserve) {
      return;
    }
    final operation = ++_epoch;
    state = EnergyPriorityViewState.busy;
    notifyListeners();
    try {
      final receipt = await api.confirmReserve(value);
      if (!_operationCurrent(operation)) return _stale();
      if (!receipt.exactFor(value)) {
        state = EnergyPriorityViewState.failed;
      } else {
        final readback = await api.readbackReserve(value);
        if (!_operationCurrent(operation)) return _stale();
        state = readback.exactFor(value) && readback == receipt
            ? EnergyPriorityViewState.verified
            : EnergyPriorityViewState.failed;
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
    reservePending = null;
    state = EnergyPriorityViewState.ready;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    snapshot = null;
    pending = null;
    reservePending = null;
    reserveSources = const [];
    selectedReserveSource = null;
    super.dispose();
  }
}
