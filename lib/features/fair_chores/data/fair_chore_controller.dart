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
  const _PendingCommand(
    this.id,
    this.action,
    this.taskId,
    this.expectedRevision,
    this.expectedTitle,
  );

  final String id;
  final FairChoreAction action;
  final String? taskId;
  final int expectedRevision;
  final String? expectedTitle;
}

class FairChoreController extends ChangeNotifier {
  FairChoreController(
    this._api, {
    required this.commandIds,
    this.onAuthorityChanged,
  });

  final FairChoreApi _api;
  final String Function() commandIds;
  final VoidCallback? onAuthorityChanged;
  FairChoreAuthority? _authority;
  List<FairChoreTask> _tasks = const [];
  List<FairChoreMember> _members = const [];
  FairChoreViewState _state = FairChoreViewState.detached;
  _PendingCommand? _pending;
  int _epoch = 0;

  FairChoreAuthority? get authority => _authority;
  List<FairChoreTask> get tasks => List.unmodifiable(_tasks);
  List<FairChoreMember> get members => List.unmodifiable(_members);
  FairChoreViewState get state => _state;

  FairChoreLease bind(FairChoreAuthority authority) {
    _epoch++;
    _authority = authority;
    _tasks = const [];
    _members = const [];
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
    _members = const [];
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

  bool _authorityFailure(Object error, FairChoreLease lease) {
    if (error is! FormatException || error.message != 'authority_changed') {
      return false;
    }
    if (_current(lease)) {
      _tasks = const [];
      _members = const [];
      _pending = null;
      _set(FairChoreViewState.error);
      onAuthorityChanged?.call();
    }
    return true;
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
      _members = List.unmodifiable(page.members);
      _set(
        _tasks.isEmpty ? FairChoreViewState.empty : FairChoreViewState.ready,
      );
    } on TimeoutException {
      if (_current(lease)) _set(FairChoreViewState.offline);
    } on FormatException catch (error) {
      if (!_authorityFailure(error, lease) && _current(lease)) {
        _set(FairChoreViewState.error);
      }
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
      receipt.action == pending.action &&
      (pending.taskId == null || receipt.task.id == pending.taskId) &&
      receipt.task.revision == pending.expectedRevision + 1 &&
      (pending.expectedTitle == null ||
          receipt.task.title == pending.expectedTitle);

  void _accept(FairChoreReceipt receipt) {
    final found = _tasks.any((item) => item.id == receipt.task.id);
    _tasks = List.unmodifiable(
      [
        for (final item in _tasks)
          if (item.id == receipt.task.id) receipt.task else item,
        if (!found) receipt.task,
      ]..sort((left, right) => left.dueAt.compareTo(right.dueAt)),
    );
    _pending = null;
    _set(_tasks.isEmpty ? FairChoreViewState.empty : FairChoreViewState.ready);
  }

  Future<void> complete(FairChoreLease lease, FairChoreTask candidate) async {
    if (!candidate.permissions.complete) return;
    await _mutate(lease, candidate, FairChoreAction.completed);
  }

  Future<void> create(
    FairChoreLease lease, {
    required String title,
    required String timezone,
    required int intervalDays,
    required DateTime dueAt,
  }) async {
    final safeTitle = title.trim();
    final safeTimezone = timezone.trim();
    if (!_current(lease) ||
        !lease.authority.canManage ||
        _state == FairChoreViewState.busy ||
        _state == FairChoreViewState.uncertain ||
        _pending != null ||
        safeTitle.isEmpty ||
        safeTitle.length > 200 ||
        safeTimezone.isEmpty ||
        safeTimezone.length > 128 ||
        intervalDays < 1 ||
        intervalDays > 365) {
      return;
    }
    final pending = _PendingCommand(
      commandIds(),
      FairChoreAction.created,
      null,
      0,
      safeTitle,
    );
    _pending = pending;
    _set(FairChoreViewState.busy);
    try {
      final commands = _api;
      if (commands is! FairChoreCommandApi) {
        throw StateError('create_not_supported');
      }
      final receipt = await commands.create(
        lease.authority,
        commandId: pending.id,
        title: safeTitle,
        timezone: safeTimezone,
        intervalDays: intervalDays,
        dueAt: dueAt,
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
    } on FormatException catch (error) {
      if (!_authorityFailure(error, lease) && _current(lease)) {
        _pending = null;
        _set(FairChoreViewState.error);
      }
    } catch (_) {
      if (_current(lease)) {
        _pending = null;
        _set(FairChoreViewState.error);
      }
    }
  }

  Future<void> defer(
    FairChoreLease lease,
    FairChoreTask candidate, {
    required int days,
  }) async {
    if (days < 1 || days > 30) return;
    if (!candidate.permissions.defer) return;
    await _mutate(lease, candidate, FairChoreAction.deferred, days: days);
  }

  Future<void> skip(FairChoreLease lease, FairChoreTask candidate) async {
    if (!candidate.permissions.skip) return;
    if (_api is! FairChoreCommandApi) return;
    await _mutate(lease, candidate, FairChoreAction.skipped);
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
    final pending = _PendingCommand(
      commandIds(),
      action,
      task.id,
      task.revision,
      null,
    );
    _pending = pending;
    _set(FairChoreViewState.busy);
    try {
      final receipt = switch (action) {
        FairChoreAction.completed => await _api.complete(
          lease.authority,
          taskId: task.id,
          expectedRevision: task.revision,
          commandId: pending.id,
        ),
        FairChoreAction.deferred => await _api.defer(
          lease.authority,
          taskId: task.id,
          expectedRevision: task.revision,
          commandId: pending.id,
          days: days,
        ),
        FairChoreAction.skipped => await (_api as FairChoreCommandApi).skip(
          lease.authority,
          taskId: task.id,
          expectedRevision: task.revision,
          commandId: pending.id,
        ),
        FairChoreAction.created => throw StateError('invalid_action'),
      };
      if (!_current(lease)) return;
      if (!_receiptMatches(receipt, lease, pending)) {
        _pending = null;
        _set(FairChoreViewState.error);
        return;
      }
      _accept(receipt);
    } on TimeoutException {
      if (_current(lease)) _set(FairChoreViewState.uncertain);
    } on FormatException catch (error) {
      if (!_authorityFailure(error, lease) && _current(lease)) {
        _pending = null;
        _set(FairChoreViewState.error);
      }
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
    } on FormatException catch (error) {
      if (!_authorityFailure(error, lease) && _current(lease)) {
        _set(FairChoreViewState.error);
      }
    } catch (_) {
      if (_current(lease)) _set(FairChoreViewState.error);
    }
  }
}
