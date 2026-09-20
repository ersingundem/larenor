import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/inventory_models.dart';
import 'inventory_api.dart';

enum InventoryFailure { invalidQr, foreignQr, offline, stale, invalidResponse }

/// Session-owned read controller. No retry, write, command or device dispatch exists.
final class InventoryController extends ChangeNotifier {
  InventoryController({
    required this.gateway,
    required this.context,
    required this.canReadGrants,
    required this.isCurrent,
  });
  final InventoryGateway gateway;
  final ServerContext context;
  final bool canReadGrants;
  final bool Function() isCurrent;
  final List<InventoryDetail> _entries = [];
  int _epoch = 0;
  bool _retired = false;
  bool busy = false;
  InventoryFailure? failure;
  InventoryDetail? selected;

  List<InventoryDetail> get entries => List.unmodifiable(_entries);
  bool get canResolve => !_retired && !busy && _current();
  bool _current() {
    try {
      return !_retired && isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _discardStale(int operation) {
    if (operation != _epoch || _retired) return;
    failure = InventoryFailure.stale;
    selected = null;
    _entries.clear();
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    busy = false;
    failure = InventoryFailure.stale;
    selected = null;
    _entries.clear();
    notifyListeners();
  }

  Future<void> resolveScanned(String value) => _resolve(value);
  Future<void> resolveManual(String value) => _resolve(value);

  Future<void> _resolve(String value) async {
    if (!canResolve) return;
    InventoryQr qr;
    try {
      qr = InventoryQr.parse(value);
    } on FormatException {
      failure = InventoryFailure.invalidQr;
      notifyListeners();
      return;
    }
    if (qr.context != context) {
      failure = InventoryFailure.foreignQr;
      notifyListeners();
      return;
    }
    final operation = ++_epoch;
    bool current() => operation == _epoch && _current();
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final item = await gateway.resolve(qr);
      if (!current() || item.context != context || item.id != qr.itemId) {
        _discardStale(operation);
        return;
      }
      final history = await gateway.history(item);
      if (!current()) {
        _discardStale(operation);
        return;
      }
      final grants = canReadGrants ? await gateway.grants(item) : null;
      if (!current()) {
        _discardStale(operation);
        return;
      }
      final detail = InventoryDetail(
        item: item,
        history: history,
        grants: grants,
      );
      _entries.removeWhere((entry) => entry.item.id == item.id);
      _entries.insert(0, detail);
      selected = detail;
    } catch (error) {
      if (!current()) {
        _discardStale(operation);
        return;
      }
      failure =
          error is LarenorServerException &&
              {
                'connection_failed',
                'timeout',
                'server_unavailable',
              }.contains(error.code)
          ? InventoryFailure.offline
          : InventoryFailure.invalidResponse;
      selected = null;
      _entries.clear();
    } finally {
      if (operation == _epoch && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void select(InventoryDetail value) {
    if (!_current() || busy || !_entries.contains(value)) return;
    selected = value;
    failure = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _retired = true;
    _epoch++;
    super.dispose();
  }
}
