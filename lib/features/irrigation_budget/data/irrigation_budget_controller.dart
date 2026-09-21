import 'package:flutter/foundation.dart';

import '../domain/irrigation_budget_models.dart';
import 'irrigation_budget_api.dart';

enum IrrigationBudgetViewState { idle, loading, ready, failed, stale }

final class IrrigationBudgetController extends ChangeNotifier {
  IrrigationBudgetController({required this.api, required this.isCurrent});
  final IrrigationBudgetApi api;
  final bool Function() isCurrent;
  int _epoch = 0;
  bool _interactive = true, _disposed = false;
  IrrigationBudgetViewState state = IrrigationBudgetViewState.idle;
  IrrigationBudgetSnapshot? snapshot;

  bool _current() {
    try {
      return !_disposed && _interactive && isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _stale() {
    snapshot = null;
    state = IrrigationBudgetViewState.stale;
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
    state = IrrigationBudgetViewState.loading;
    notifyListeners();
    try {
      final value = await api.load();
      if (operation != _epoch || !_current()) return _stale();
      if (value.isVerified) {
        snapshot = value;
        state = IrrigationBudgetViewState.ready;
      } else {
        state = IrrigationBudgetViewState.failed;
      }
    } catch (_) {
      if (operation != _epoch || !_current()) return _stale();
      state = IrrigationBudgetViewState.failed;
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
