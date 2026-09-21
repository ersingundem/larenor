import 'package:flutter/foundation.dart';

import '../domain/camera_search_models.dart';

enum CameraSearchFailure { unavailable, invalidQuery, staleAuthority }

final class CameraSearchController extends ChangeNotifier {
  CameraSearchController({
    required CameraSearchGateway gateway,
    required bool Function() isCurrent,
  }) : this._(gateway, isCurrent);

  CameraSearchController._(this._gateway, this._isCurrent);

  final CameraSearchGateway _gateway;
  final bool Function() _isCurrent;
  List<CameraSearchMatch> _results = const [];
  CameraSearchPage? _page;
  CameraSearchFailure? _failure;
  bool _busy = false, _searched = false, _retired = false;
  int _epoch = 0;

  List<CameraSearchMatch> get results => _results;
  CameraSearchPage? get page => _page;
  CameraSearchFailure? get failure => _failure;
  bool get busy => _busy;
  bool get searched => _searched;

  bool _current() {
    if (_retired) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> search(String query, CameraSearchFilter filter) async {
    final trimmed = query.trim();
    if (_busy || !_current()) return;
    if (trimmed.length < 2 || trimmed.length > 200) {
      _results = const [];
      _failure = CameraSearchFailure.invalidQuery;
      _searched = true;
      notifyListeners();
      return;
    }
    final operation = ++_epoch;
    _busy = true;
    _searched = true;
    _failure = null;
    _results = const [];
    _page = null;
    notifyListeners();
    try {
      final value = await _gateway.search(query: trimmed, filter: filter);
      if (operation != _epoch || !_current()) {
        if (!_retired) _failure = CameraSearchFailure.staleAuthority;
        return;
      }
      if (value.indexRevision != filter.expectedIndexRevision ||
          value.results.any(
            (result) =>
                result.evidence.indexRevision != filter.expectedIndexRevision ||
                !filter.cameraIds.contains(result.evidence.cameraId),
          )) {
        _failure = CameraSearchFailure.staleAuthority;
        return;
      }
      _page = value;
      _results = List.unmodifiable(value.results);
    } catch (_) {
      if (operation == _epoch && _current()) {
        _failure = CameraSearchFailure.unavailable;
      }
    } finally {
      if (operation == _epoch && !_retired) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    _busy = false;
    _results = const [];
    _page = null;
    _gateway.retire();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
