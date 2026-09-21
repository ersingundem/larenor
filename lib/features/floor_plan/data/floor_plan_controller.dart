import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/floor_plan_models.dart';
import 'floor_plan_api.dart';

enum FloorPlanFailure { offline, stale, invalidResponse }

final class FloorPlanController extends ChangeNotifier {
  FloorPlanController({required this.gateway, required this.isCurrent});
  final FloorPlanGateway gateway;
  final bool Function() isCurrent;
  int _epoch = 0;
  bool _retired = false;
  bool busy = false;
  FloorPlanFailure? failure;
  FloorPlanSnapshot? snapshot;

  bool _current() {
    try {
      return !_retired && isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> load() async {
    if (busy || !_current()) return;
    final operation = ++_epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final value = await gateway.read();
      if (operation != _epoch || !_current()) {
        if (operation == _epoch && !_retired) _fail(FloorPlanFailure.stale);
        return;
      }
      snapshot = value;
    } catch (error) {
      if (operation != _epoch || !_current()) {
        if (operation == _epoch && !_retired) _fail(FloorPlanFailure.stale);
        return;
      }
      _fail(
        error is LarenorServerException &&
                {
                  'connection_failed',
                  'timeout',
                  'server_unavailable',
                }.contains(error.code)
            ? FloorPlanFailure.offline
            : error is LarenorServerException && error.code == 'cancelled'
            ? FloorPlanFailure.stale
            : FloorPlanFailure.invalidResponse,
      );
    } finally {
      if (operation == _epoch && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void _fail(FloorPlanFailure value) {
    failure = value;
    snapshot = null;
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    busy = false;
    _fail(FloorPlanFailure.stale);
    notifyListeners();
  }

  @override
  void dispose() {
    _retired = true;
    _epoch++;
    super.dispose();
  }
}
