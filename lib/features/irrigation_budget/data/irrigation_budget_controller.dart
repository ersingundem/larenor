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
  IrrigationControlPreview? preview;
  IrrigationControlReceipt? receipt;
  IrrigationStopReceipt? stopReceipt;
  bool controlBusy = false;
  String? controlError;

  IrrigationControlApi? get _control =>
      api is IrrigationControlApi ? api as IrrigationControlApi : null;
  bool get canControl =>
      snapshot?.commandEndpointAvailable == true && _control != null;

  bool _current() {
    try {
      return !_disposed && _interactive && isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _stale() {
    snapshot = null;
    preview = null;
    controlBusy = false;
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

  Future<void> createPreview() async {
    final current = snapshot, control = _control;
    if (!_current() || current == null || control == null || !canControl) {
      return;
    }
    final operation = ++_epoch;
    controlBusy = true;
    controlError = null;
    preview = null;
    notifyListeners();
    try {
      final value = await control.preview(current);
      if (operation != _epoch || !_current()) return _stale();
      if (value.planId != current.planId ||
          value.policyRevision != current.authority.policyRevision) {
        throw StateError('irrigation_preview_changed');
      }
      preview = value;
    } catch (_) {
      if (operation != _epoch || !_current()) return _stale();
      controlError = 'preview_failed';
    }
    controlBusy = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> confirmPreview() async {
    final current = preview, control = _control;
    if (!_current() || current == null || control == null) return;
    final operation = ++_epoch;
    controlBusy = true;
    controlError = null;
    notifyListeners();
    try {
      final value = await control.confirm(current);
      if (operation != _epoch || !_current()) return _stale();
      if (value.requestId != current.requestId ||
          value.planId != current.planId) {
        throw StateError('irrigation_receipt_changed');
      }
      receipt = value;
      preview = null;
    } catch (_) {
      if (operation != _epoch || !_current()) return _stale();
      controlError = 'confirm_failed';
    }
    controlBusy = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> safeStop() async {
    final current = snapshot, control = _control;
    if (!_current() || current == null || control == null || !canControl) {
      return;
    }
    final operation = ++_epoch;
    controlBusy = true;
    controlError = null;
    notifyListeners();
    try {
      final value = await control.stop(
        current,
        current.zones.map((zone) => zone.zoneId).toList(growable: false),
      );
      if (operation != _epoch || !_current()) return _stale();
      stopReceipt = value;
    } catch (_) {
      if (operation != _epoch || !_current()) return _stale();
      controlError = 'stop_failed';
    }
    controlBusy = false;
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
