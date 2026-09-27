import 'package:flutter/foundation.dart';

import '../domain/power_budget_models.dart';
import 'power_budget_api.dart';

enum PowerBudgetViewState { idle, loading, ready, failed, stale }

final class PowerBudgetController extends ChangeNotifier {
  PowerBudgetController({required this.api, required this.isCurrent});
  final PowerBudgetApi api;
  final bool Function() isCurrent;
  int _epoch = 0;
  bool _interactive = true, _disposed = false;
  PowerBudgetViewState state = PowerBudgetViewState.idle;
  PowerBudgetSnapshot? snapshot;
  PowerBudgetReceipt? receipt;

  bool _current() {
    try {
      return !_disposed && _interactive && isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _stale() {
    snapshot = null;
    receipt = null;
    state = PowerBudgetViewState.stale;
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
    if (!_current()) return _stale();
    final operation = ++_epoch;
    snapshot = null;
    receipt = null;
    state = PowerBudgetViewState.loading;
    notifyListeners();
    try {
      final value = await api.load();
      if (operation != _epoch || !_current()) return _stale();
      if (!value.isVerified) {
        state = PowerBudgetViewState.failed;
      } else {
        snapshot = value;
        state = PowerBudgetViewState.ready;
      }
    } catch (_) {
      if (operation != _epoch || !_current()) return _stale();
      state = PowerBudgetViewState.failed;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> confirm() async {
    final current = snapshot;
    if (!_current() ||
        current == null ||
        !current.commandEndpointAvailable ||
        state != PowerBudgetViewState.ready) {
      return _stale();
    }
    final operation = ++_epoch;
    state = PowerBudgetViewState.loading;
    receipt = null;
    notifyListeners();
    try {
      final result = await api.confirm(current);
      if (operation != _epoch || !_current()) return _stale();
      receipt = result;
      state = PowerBudgetViewState.ready;
    } catch (_) {
      if (operation != _epoch || !_current()) return _stale();
      receipt = const PowerBudgetReceipt(
        commandId: 'unavailable',
        previewId: 'unavailable',
        planHash: 'unavailable',
        status: 'uncertain',
        applyCount: 1,
      );
      state = PowerBudgetViewState.failed;
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
