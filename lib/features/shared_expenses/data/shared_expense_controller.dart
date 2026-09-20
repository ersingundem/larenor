import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/shared_expense_models.dart';

enum SharedExpenseViewState {
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

class SharedExpenseLease {
  const SharedExpenseLease._(this.epoch, this.authority);

  final int epoch;
  final SharedExpenseAuthority authority;
}

class _PendingExpense {
  const _PendingExpense(
    this.commandId,
    this.expectedLedgerRevision,
    this.draft,
  );

  final String commandId;
  final int expectedLedgerRevision;
  final ExpenseDraft draft;
}

class SharedExpenseController extends ChangeNotifier {
  SharedExpenseController(this._api, {required this.commandIds});

  final SharedExpenseApi _api;
  final String Function() commandIds;
  SharedExpenseAuthority? _authority;
  SharedExpenseViewState _state = SharedExpenseViewState.detached;
  List<ExpenseParticipant> _participants = const [];
  List<SharedExpenseRecord> _records = const [];
  List<SharedExpenseRecord> _exportedRecords = const [];
  int? _ledgerRevision;
  int? _membersRevision;
  int _epoch = 0;
  _PendingExpense? _pending;

  SharedExpenseAuthority? get authority => _authority;
  SharedExpenseViewState get state => _state;
  List<ExpenseParticipant> get participants => List.unmodifiable(_participants);
  List<SharedExpenseRecord> get records => List.unmodifiable(_records);
  List<SharedExpenseRecord> get exportedRecords =>
      List.unmodifiable(_exportedRecords);
  int? get ledgerRevision => _ledgerRevision;

  SharedExpenseLease bind(SharedExpenseAuthority authority) {
    _epoch++;
    _authority = authority;
    _state = SharedExpenseViewState.idle;
    _participants = const [];
    _records = const [];
    _exportedRecords = const [];
    _ledgerRevision = null;
    _membersRevision = null;
    _pending = null;
    notifyListeners();
    return SharedExpenseLease._(_epoch, authority);
  }

  bool _current(SharedExpenseLease lease) =>
      lease.epoch == _epoch && lease.authority == _authority;

  void detach(SharedExpenseLease lease) {
    if (!_current(lease)) return;
    _epoch++;
    _authority = null;
    _state = SharedExpenseViewState.detached;
    _participants = const [];
    _records = const [];
    _exportedRecords = const [];
    _ledgerRevision = null;
    _membersRevision = null;
    _pending = null;
    notifyListeners();
  }

  void _set(SharedExpenseViewState state) {
    _state = state;
    notifyListeners();
  }

  Future<void> load(SharedExpenseLease lease) async {
    if (!_current(lease) ||
        _state == SharedExpenseViewState.loading ||
        _pending != null) {
      return;
    }
    _set(SharedExpenseViewState.loading);
    try {
      final result = await _api.snapshot(lease.authority);
      if (!_current(lease)) return;
      if (result.authority != lease.authority ||
          result.ledgerRevision < 1 ||
          result.membersRevision < 1 ||
          result.participants.isEmpty) {
        _set(SharedExpenseViewState.error);
        return;
      }
      _ledgerRevision = result.ledgerRevision;
      _membersRevision = result.membersRevision;
      _participants = result.participants;
      _records = result.records;
      _exportedRecords = const [];
      _set(
        _records.isEmpty
            ? SharedExpenseViewState.empty
            : SharedExpenseViewState.ready,
      );
    } on TimeoutException {
      if (_current(lease)) _set(SharedExpenseViewState.offline);
    } catch (_) {
      if (_current(lease)) _set(SharedExpenseViewState.error);
    }
  }

  bool _matches(
    SharedExpenseReceipt receipt,
    SharedExpenseLease lease,
    _PendingExpense pending,
  ) =>
      receipt.authority == lease.authority &&
      receipt.commandId == pending.commandId &&
      receipt.ledgerRevision == pending.expectedLedgerRevision + 1 &&
      receipt.record.matchesDraft(pending.draft);

  void _accept(SharedExpenseReceipt receipt) {
    _records = List.unmodifiable([..._records, receipt.record]);
    _ledgerRevision = receipt.ledgerRevision;
    _pending = null;
    _set(SharedExpenseViewState.ready);
  }

  Future<void> create(SharedExpenseLease lease, ExpenseDraft draft) async {
    final ledgerRevision = _ledgerRevision;
    final membersRevision = _membersRevision;
    if (!_current(lease) ||
        ledgerRevision == null ||
        membersRevision == null ||
        _pending != null ||
        (_state != SharedExpenseViewState.ready &&
            _state != SharedExpenseViewState.empty)) {
      return;
    }
    final pending = _PendingExpense(commandIds(), ledgerRevision, draft);
    _pending = pending;
    _set(SharedExpenseViewState.busy);
    try {
      final receipt = await _api.create(
        lease.authority,
        expectedLedgerRevision: ledgerRevision,
        expectedMembersRevision: membersRevision,
        commandId: pending.commandId,
        draft: draft,
      );
      if (!_current(lease)) return;
      if (!_matches(receipt, lease, pending)) {
        _pending = null;
        _set(SharedExpenseViewState.error);
        return;
      }
      _accept(receipt);
    } on TimeoutException {
      if (_current(lease)) _set(SharedExpenseViewState.uncertain);
    } catch (_) {
      if (_current(lease)) {
        _pending = null;
        _set(SharedExpenseViewState.error);
      }
    }
  }

  Future<void> reconcile(SharedExpenseLease lease) async {
    final pending = _pending;
    if (!_current(lease) ||
        pending == null ||
        _state != SharedExpenseViewState.uncertain) {
      return;
    }
    try {
      final receipt = await _api.receipt(lease.authority, pending.commandId);
      if (!_current(lease) || receipt == null) return;
      if (!_matches(receipt, lease, pending)) {
        _pending = null;
        _set(SharedExpenseViewState.error);
        return;
      }
      _accept(receipt);
    } on TimeoutException {
      // Keep the single command uncertain; never replay the write.
    } catch (_) {
      if (_current(lease)) _set(SharedExpenseViewState.uncertain);
    }
  }

  Future<void> readExport(SharedExpenseLease lease) async {
    final revision = _ledgerRevision;
    if (!_current(lease) ||
        revision == null ||
        _pending != null ||
        (_state != SharedExpenseViewState.ready &&
            _state != SharedExpenseViewState.empty)) {
      return;
    }
    try {
      final result = await _api.export(
        lease.authority,
        ledgerRevision: revision,
      );
      if (!_current(lease)) return;
      if (result.authority != lease.authority ||
          result.ledgerRevision != revision) {
        _exportedRecords = const [];
        _set(SharedExpenseViewState.error);
        return;
      }
      _exportedRecords = result.records;
      notifyListeners();
    } on TimeoutException {
      if (_current(lease)) _set(SharedExpenseViewState.offline);
    } catch (_) {
      if (_current(lease)) _set(SharedExpenseViewState.error);
    }
  }
}
