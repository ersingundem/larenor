import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/inventory_models.dart';
import 'inventory_api.dart';

enum InventoryCatalogFailure { offline, stale, invalidResponse }

/// Route-owned, read-only Core catalog. Pages are accepted only while the
/// original account/route/lifecycle authority remains current.
final class InventoryCatalogController extends ChangeNotifier {
  InventoryCatalogController({
    required this.gateway,
    required this.isCurrent,
    this.pageSize = 25,
    this.maximumEntries = 100,
  }) : assert(pageSize >= 1 && pageSize <= 100),
       assert(maximumEntries >= pageSize && maximumEntries <= 100);

  final InventoryCatalogGateway gateway;
  final bool Function() isCurrent;
  final int pageSize;
  final int maximumEntries;
  final List<InventoryItem> _items = [];
  int _epoch = 0;
  bool _retired = false;
  String? _nextCursor;
  bool busy = false;
  InventoryCatalogFailure? failure;

  List<InventoryItem> get items => List.unmodifiable(_items);
  bool get hasNext => !_retired && _nextCursor != null;
  bool get canRead => !_retired && !busy && _current();

  bool _current() {
    try {
      return !_retired && isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() => _load(replace: true);

  Future<void> loadNext() {
    if (_nextCursor == null) return Future.value();
    return _load(replace: false);
  }

  Future<void> _load({required bool replace}) async {
    if (!canRead || !replace && _nextCursor == null) return;
    final operation = ++_epoch;
    final cursor = replace ? null : _nextCursor;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final page = await gateway.list(limit: pageSize, cursor: cursor);
      if (operation != _epoch || !_current()) {
        if (operation == _epoch && !_retired) {
          _fail(InventoryCatalogFailure.stale);
        }
        return;
      }
      final candidate = replace ? <InventoryItem>[] : [..._items];
      final known = candidate.map((item) => item.id).toSet();
      for (final item in page.items) {
        if (!known.add(item.id) || candidate.length >= maximumEntries) {
          _fail(InventoryCatalogFailure.invalidResponse);
          return;
        }
        candidate.add(item);
      }
      if (page.nextCursor != null && candidate.length >= maximumEntries) {
        _fail(InventoryCatalogFailure.invalidResponse);
        return;
      }
      _items
        ..clear()
        ..addAll(candidate);
      _nextCursor = page.nextCursor;
    } catch (error) {
      if (operation != _epoch || !_current()) {
        if (operation == _epoch && !_retired) {
          _fail(InventoryCatalogFailure.stale);
        }
        return;
      }
      _fail(
        error is LarenorServerException &&
                {
                  'connection_failed',
                  'timeout',
                  'server_unavailable',
                }.contains(error.code)
            ? InventoryCatalogFailure.offline
            : InventoryCatalogFailure.invalidResponse,
      );
      return;
    } finally {
      if (operation == _epoch && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void _fail(InventoryCatalogFailure value) {
    failure = value;
    _items.clear();
    _nextCursor = null;
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    busy = false;
    _fail(InventoryCatalogFailure.stale);
    notifyListeners();
  }

  @override
  void dispose() {
    _retired = true;
    _epoch++;
    super.dispose();
  }
}
