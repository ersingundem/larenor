import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/fair_chore_models.dart';

enum FairChoreViewState {
  detached,
  idle,
  loading,
  ready,
  empty,
  busy,
  uncertain,
  offline,
  error,
}

class FairChoreLease {
  const FairChoreLease._(this.epoch, this.authority);

  final int epoch;
  final FairChoreAuthority authority;
}

class _PendingCommand {
  const _PendingCommand(this.id, this.action);

  final String id;
  final FairChoreAction action;
}

class FairChoreController extends ChangeNotifier {
  FairChoreController(this._api, {required String Function() commandIds})
    : _commandIds = commandIds;

  final FairChoreApi _api;
  final String Function() _commandIds;
  FairChoreAuthority? _authority;
  List<FairChoreTask> _tasks = const [];
  FairChoreViewState _state = FairChoreViewState.detached;
  _PendingCommand? _pending;
  int _epoch = 0;

  FairChoreAuthority? get authority => _authority;
  List<FairChoreTask> get tasks => List.unmodifiable(_tasks);
  FairChoreViewState get state => _state;

  FairChoreLease bind(FairChoreAuthority authority) {
    _epoch++;
    _authority = authority;
    _tasks = const [];
    _pending = null;
    _state = FairChoreViewState.idle;
    notifyListeners();
    return FairChoreLease._(_epoch, authority);
  }

  void detach(FairChoreLease lease) {
    if (!_current(lease)) return;
    _epoch++;
    _authority = null;
    _tasks = const [];
    _pending = null;
    _state = FairChoreViewState.detached;
    notifyListeners();
  }

  bool _current(FairChoreLease lease) =>
      lease.epoch == _epoch && lease.authority == _authority;

  void _set(FairChoreViewState value) {
    _state = value;
    notifyListeners();
  }

  Future<void> load(FairChoreLease lease) async {
    if (!_current(lease) || _state == FairChoreViewState.loading) return;
    _set(FairChoreViewState.loading);
    try {
      final page = await _api.list(lease.authority);
      if (!_current(lease)) return;
      if (page.authority != lease.authority) {
        _tasks = const [];
        _set(FairChoreViewState.error);
        return;
      }
      _tasks = List.unmodifiable(page.tasks);
      _set(
        _tasks.isEmpty ? FairChoreViewState.empty : FairChoreViewState.ready,
      );
    } on TimeoutException {
      if (_current(lease)) _set(FairChoreViewState.offline);
    } catch (_) {
      if (_current(lease)) _set(FairChoreViewState.error);
    }
  }

  FairChoreTask? _currentTask(FairChoreTask candidate) {
    for (final item in _tasks) {
      if (item.id == candidate.id && item.revision == candidate.revision) {
        return item;
      }
    }
    return null;
  }

  bool _receiptMatches(
    FairChoreReceipt receipt,
    FairChoreLease lease,
    _PendingCommand pending,
  ) =>
      receipt.authority == lease.authority &&
      receipt.commandId == pending.id &&
      receipt.action == pending.action;

  void _accept(FairChoreReceipt receipt) {
    _tasks = List.unmodifiable([
      for (final item in _tasks)
        if (item.id == receipt.task.id) receipt.task else item,
    ]);
    _pending = null;
    _set(_tasks.isEmpty ? FairChoreViewState.empty : FairChoreViewState.ready);
  }

  Future<void> complete(FairChoreLease lease, FairChoreTask candidate) async {
    await _mutate(lease, candidate, FairChoreAction.completed);
  }

  Future<void> defer(
    FairChoreLease lease,
    FairChoreTask candidate, {
    required int days,
  }) async {
    if (days < 1 || days > 30) return;
    await _mutate(lease, candidate, FairChoreAction.deferred, days: days);
  }

  Future<void> _mutate(
    FairChoreLease lease,
    FairChoreTask candidate,
    FairChoreAction action, {
    int days = 1,
  }) async {
    if (!_current(lease) ||
        _state == FairChoreViewState.busy ||
        _state == FairChoreViewState.uncertain ||
        _pending != null) {
      return;
    }
    final task = _currentTask(candidate);
    if (task == null) {
      _set(FairChoreViewState.error);
      return;
    }
    final pending = _PendingCommand(_commandIds(), action);
    _pending = pending;
    _set(FairChoreViewState.busy);
    try {
      final receipt = action == FairChoreAction.completed
          ? await _api.complete(
              lease.authority,
              taskId: task.id,
              expectedRevision: task.revision,
              commandId: pending.id,
            )
          : await _api.defer(
              lease.authority,
              taskId: task.id,
              expectedRevision: task.revision,
              commandId: pending.id,
              days: days,
            );
      if (!_current(lease)) return;
      if (!_receiptMatches(receipt, lease, pending)) {
        _pending = null;
        _set(FairChoreViewState.error);
        return;
      }
      _accept(receipt);
    } on TimeoutException {
      if (_current(lease)) _set(FairChoreViewState.uncertain);
    } catch (_) {
      if (_current(lease)) {
        _pending = null;
        _set(FairChoreViewState.error);
      }
    }
  }

  Future<void> reconcile(FairChoreLease lease) async {
    final pending = _pending;
    if (!_current(lease) ||
        pending == null ||
        _state != FairChoreViewState.uncertain) {
      return;
    }
    try {
      final receipt = await _api.receipt(lease.authority, pending.id);
      if (!_current(lease)) return;
      if (receipt == null) return;
      if (!_receiptMatches(receipt, lease, pending)) {
        _pending = null;
        _set(FairChoreViewState.error);
        return;
      }
      _accept(receipt);
    } on TimeoutException {
      // Retain the uncertain command. A later explicit read may reconcile it.
    } catch (_) {
      if (_current(lease)) _set(FairChoreViewState.error);
    }
  }
}
