import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/floor_plan_models.dart';
import 'floor_plan_api.dart';

enum FloorPlanFailure { offline, stale, invalidResponse }

enum FloorPlanActionState { idle, busy, uncertain, succeeded, rejected, failed }

final class FloorPlanController extends ChangeNotifier {
  FloorPlanController({
    required this.gateway,
    required this.isCurrent,
    String Function()? requestIds,
  }) : _requestIds = requestIds ?? _randomId;

  final FloorPlanGateway gateway;
  final bool Function() isCurrent;
  final String Function() _requestIds;
  int _epoch = 0;
  bool _retired = false;
  bool busy = false;
  bool actionBusy = false;
  FloorPlanFailure? failure;
  FloorPlanSnapshot? snapshot;
  FloorPlanActionState actionState = FloorPlanActionState.idle;
  String? actionAnchorId;
  FloorPlanActionRequest? _pendingAction;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

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
      _reconcile(value);
    } catch (error) {
      if (operation != _epoch || !_current()) {
        if (operation == _epoch && !_retired) _fail(FloorPlanFailure.stale);
        return;
      }
      _fail(_readFailure(error));
    } finally {
      if (operation == _epoch && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> dispatch(String anchorId, FloorPlanAction action) async {
    final currentSnapshot = snapshot;
    final projection = currentSnapshot?.projections[anchorId];
    final actionGateway = gateway is FloorPlanActionGateway
        ? gateway as FloorPlanActionGateway
        : null;
    if (!_current() ||
        busy ||
        actionBusy ||
        _pendingAction != null ||
        currentSnapshot == null ||
        projection == null ||
        !projection.capability.actions.contains(action) ||
        actionGateway == null) {
      return;
    }
    final request = FloorPlanActionRequest.forProjection(
      requestId: _requestIds(),
      snapshot: currentSnapshot,
      projection: projection,
      action: action,
    );
    final operation = ++_epoch;
    _pendingAction = request;
    actionAnchorId = anchorId;
    actionBusy = true;
    actionState = FloorPlanActionState.busy;
    notifyListeners();
    var refresh = false;
    try {
      final receipt = await actionGateway.action(
        request,
        expectedSnapshot: currentSnapshot,
      );
      if (operation != _epoch || !_current()) return;
      switch (receipt.dispatchState) {
        case FloorPlanDispatchState.accepted:
          _pendingAction = null;
          actionState = FloorPlanActionState.succeeded;
          refresh = true;
        case FloorPlanDispatchState.rejected:
          _pendingAction = null;
          actionState = FloorPlanActionState.rejected;
        case FloorPlanDispatchState.pending:
        case FloorPlanDispatchState.unknown:
          actionState = FloorPlanActionState.uncertain;
          refresh = true;
      }
    } catch (error) {
      if (operation != _epoch || !_current()) return;
      final code = error is LarenorServerException ? error.code : '';
      if (!{
        'invalid_request',
        'unauthorized',
        'forbidden',
        'not_found',
        'conflict',
        'rate_limited',
      }.contains(code)) {
        // The POST may have reached Core. Retain this request and reconcile
        // with GET; never replay it automatically or from the refresh button.
        actionState = FloorPlanActionState.uncertain;
        refresh = true;
      } else {
        _pendingAction = null;
        actionState = FloorPlanActionState.failed;
        refresh = code == 'conflict';
      }
    } finally {
      if (operation == _epoch && !_retired) {
        actionBusy = false;
        notifyListeners();
      }
    }
    if (refresh && operation == _epoch && _current()) await load();
  }

  void clearActionStatus() {
    if (actionBusy || actionState == FloorPlanActionState.uncertain) return;
    actionState = FloorPlanActionState.idle;
    actionAnchorId = null;
    notifyListeners();
  }

  void _reconcile(FloorPlanSnapshot value) {
    final pending = _pendingAction;
    if (pending == null) return;
    final projection = value.projections[pending.anchorId];
    final targetState = switch (pending.action) {
      FloorPlanAction.turnOn => 'on',
      FloorPlanAction.turnOff => 'off',
    };
    if (projection != null &&
        projection.status == FloorPlanProjectionStatus.live &&
        projection.state == targetState) {
      _pendingAction = null;
      actionState = FloorPlanActionState.succeeded;
    } else {
      actionState = FloorPlanActionState.uncertain;
    }
  }

  FloorPlanFailure _readFailure(Object error) =>
      error is LarenorServerException &&
          {
            'connection_failed',
            'timeout',
            'server_unavailable',
            'server_error',
          }.contains(error.code)
      ? FloorPlanFailure.offline
      : error is LarenorServerException && error.code == 'cancelled'
      ? FloorPlanFailure.stale
      : FloorPlanFailure.invalidResponse;

  void _fail(FloorPlanFailure value) {
    failure = value;
    snapshot = null;
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    busy = false;
    actionBusy = false;
    _pendingAction = null;
    actionState = FloorPlanActionState.idle;
    _fail(FloorPlanFailure.stale);
    notifyListeners();
  }

  @override
  void dispose() {
    _retired = true;
    _epoch++;
    _pendingAction = null;
    super.dispose();
  }
}
