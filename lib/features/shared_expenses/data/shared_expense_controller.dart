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

class _PendingCommand {
  const _PendingCommand.expense(
    this.commandId,
    this.expectedLedgerRevision,
    ExpenseDraft value,
  ) : expense = value,
      payment = null,
      replacesId = null;

  const _PendingCommand.payment(
    this.commandId,
    this.expectedLedgerRevision,
    ExpensePaymentDraft value,
  ) : expense = null,
      payment = value,
      replacesId = null;

  const _PendingCommand.correction(
    this.commandId,
    this.expectedLedgerRevision,
    ExpenseDraft value,
    this.replacesId,
  ) : expense = value,
      payment = null;

  final String commandId;
  final int expectedLedgerRevision;
  final ExpenseDraft? expense;
  final ExpensePaymentDraft? payment;
  final String? replacesId;

  bool matches(SharedExpenseRecord record) {
    final expenseDraft = expense;
    if (expenseDraft != null) {
      return record.matchesDraft(expenseDraft) &&
          record.replacesId == replacesId;
    }
    final paymentDraft = payment;
    if (paymentDraft != null) return record.matchesPayment(paymentDraft);
    return false;
  }
}

class SharedExpenseController extends ChangeNotifier {
  SharedExpenseController(this._api, {required this.commandIds});

  final SharedExpenseApi _api;
  final String Function() commandIds;
  SharedExpenseAuthority? _authority;
  SharedExpenseViewState _state = SharedExpenseViewState.detached;
  List<ExpenseParticipant> _participants = const [];
  List<SharedExpenseRecord> _records = const [];
  List<ExpenseBalance> _balances = const [];
  List<ExpenseSettlement> _settlements = const [];
  List<SharedExpenseRecord> _exportedRecords = const [];
  int? _ledgerRevision;
  int? _membersRevision;
  int _epoch = 0;
  _PendingCommand? _pending;

  SharedExpenseAuthority? get authority => _authority;
  SharedExpenseViewState get state => _state;
  List<ExpenseParticipant> get participants => List.unmodifiable(_participants);
  List<SharedExpenseRecord> get records => List.unmodifiable(_records);
  List<ExpenseBalance> get balances => List.unmodifiable(_balances);
  List<ExpenseSettlement> get settlements => List.unmodifiable(_settlements);
  List<SharedExpenseRecord> get exportedRecords =>
      List.unmodifiable(_exportedRecords);
  int? get ledgerRevision => _ledgerRevision;

  String get exportText {
    if (_exportedRecords.isEmpty) return '';
    String cell(Object value) {
      var text = value.toString();
      if (RegExp(r'^[\s]*[=+\-@]').hasMatch(text)) text = "'$text";
      return '"${text.replaceAll('"', '""')}"';
    }

    final labels = {for (final value in _participants) value.id: value.label};
    final rows = <String>[
      'id,replaces_id,superseded,kind,created_at,title,currency,total,payer,shares',
    ];
    for (final record in _exportedRecords) {
      final shares = record.shares
          .map(
            (share) =>
                '${labels[share.accountId] ?? share.accountId}='
                '${formatExpenseMinor(share.amountMinor, record.currencyScale)}',
          )
          .join('; ');
      rows.add(
        [
          record.id,
          record.replacesId ?? '',
          record.superseded,
          record.kind.name,
          DateTime.fromMillisecondsSinceEpoch(
            (record.createdAt * 1000).round(),
            isUtc: true,
          ).toIso8601String(),
          record.title,
          record.currency,
          formatExpenseMinor(record.totalMinor, record.currencyScale),
          labels[record.payerId] ?? record.payerId,
          shares,
        ].map(cell).join(','),
      );
    }
    return rows.join('\n');
  }

  SharedExpenseLease bind(SharedExpenseAuthority authority) {
    _epoch++;
    _authority = authority;
    _state = SharedExpenseViewState.idle;
    _participants = const [];
    _records = const [];
    _balances = const [];
    _settlements = const [];
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
    _balances = const [];
    _settlements = const [];
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

  bool _validHistory(List<SharedExpenseRecord> records, bool canViewAll) {
    if (records.length > 1000) return false;
    final byId = <String, SharedExpenseRecord>{};
    final replaced = <String>{};
    for (final record in records) {
      if (byId.containsKey(record.id) ||
          (record.kind == SharedExpenseKind.payment &&
              (record.superseded || record.replacesId != null))) {
        return false;
      }
      byId[record.id] = record;
      final previous = record.replacesId;
      if (previous != null && !replaced.add(previous)) return false;
    }
    for (final record in records) {
      final previous = record.replacesId;
      if (previous != null) {
        final predecessor = byId[previous];
        if (predecessor == null) {
          if (canViewAll) return false;
        } else if (predecessor.kind != SharedExpenseKind.expense ||
            predecessor.payerId != record.payerId ||
            predecessor.currency != record.currency ||
            !predecessor.superseded) {
          return false;
        }
      }
      if (canViewAll && record.superseded != replaced.contains(record.id)) {
        return false;
      }
      // A member may have a filtered predecessor. Visible cycles are invalid.
      final seen = <String>{};
      SharedExpenseRecord? cursor = record;
      while (cursor != null) {
        if (!seen.add(cursor.id)) return false;
        cursor = byId[cursor.replacesId];
      }
    }
    return true;
  }

  Future<void> load(SharedExpenseLease lease) async {
    if (!_current(lease) ||
        _state == SharedExpenseViewState.loading ||
        _pending != null) {
      return;
    }
    _participants = const [];
    _records = const [];
    _balances = const [];
    _settlements = const [];
    _exportedRecords = const [];
    _ledgerRevision = null;
    _membersRevision = null;
    _set(SharedExpenseViewState.loading);
    try {
      final result = await _api.snapshot(lease.authority);
      if (!_current(lease)) return;
      if (!_validHistory(result.records, lease.authority.canViewAll) ||
          result.authority != lease.authority ||
          result.ledgerRevision < 1 ||
          result.membersRevision != lease.authority.membersRevision ||
          result.participants.isEmpty ||
          result.participants.length > 256 ||
          result.records.length > 1000 ||
          !result.participants.any(
            (participant) => participant.id == lease.authority.accountId,
          ) ||
          result.balances.any(
            (balance) =>
                !lease.authority.canViewAll &&
                balance.accountId != lease.authority.accountId,
          ) ||
          result.settlements.any(
            (settlement) =>
                !lease.authority.canViewAll &&
                settlement.debtorId != lease.authority.accountId &&
                settlement.creditorId != lease.authority.accountId,
          ) ||
          result.records.any(
            (record) =>
                !lease.authority.canViewAll &&
                record.payerId != lease.authority.accountId &&
                !record.shares.any(
                  (share) => share.accountId == lease.authority.accountId,
                ),
          )) {
        _set(SharedExpenseViewState.error);
        return;
      }
      _ledgerRevision = result.ledgerRevision;
      _membersRevision = result.membersRevision;
      _participants = result.participants;
      _records = result.records;
      _balances = result.balances;
      _settlements = result.settlements;
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
    _PendingCommand pending,
  ) =>
      receipt.authority == lease.authority &&
      receipt.commandId == pending.commandId &&
      receipt.ledgerRevision == pending.expectedLedgerRevision + 1 &&
      pending.matches(receipt.record);

  Future<void> _accept(
    SharedExpenseLease lease,
    SharedExpenseReceipt receipt,
  ) async {
    _records = List.unmodifiable([..._records, receipt.record]);
    _ledgerRevision = receipt.ledgerRevision;
    _pending = null;
    _set(SharedExpenseViewState.ready);
    await load(lease);
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
    final pending = _PendingCommand.expense(
      commandIds(),
      ledgerRevision,
      draft,
    );
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
      await _accept(lease, receipt);
    } on TimeoutException {
      if (_current(lease)) _set(SharedExpenseViewState.uncertain);
    } catch (_) {
      if (_current(lease)) {
        _pending = null;
        _set(SharedExpenseViewState.error);
      }
    }
  }

  Future<void> createPayment(
    SharedExpenseLease lease,
    ExpensePaymentDraft draft,
  ) async {
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
    final pending = _PendingCommand.payment(
      commandIds(),
      ledgerRevision,
      draft,
    );
    final paymentApi = _api is SharedExpensePaymentApi
        ? _api as SharedExpensePaymentApi
        : null;
    if (paymentApi == null) {
      _set(SharedExpenseViewState.error);
      return;
    }
    _pending = pending;
    _set(SharedExpenseViewState.busy);
    try {
      final receipt = await paymentApi.payment(
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
      await _accept(lease, receipt);
    } on TimeoutException {
      if (_current(lease)) _set(SharedExpenseViewState.uncertain);
    } catch (_) {
      if (_current(lease)) {
        _pending = null;
        _set(SharedExpenseViewState.error);
      }
    }
  }

  bool canCorrect(SharedExpenseRecord record) =>
      _authority != null &&
      _api is SharedExpenseCorrectionApi &&
      !record.superseded &&
      _participants.any((value) => value.id == record.payerId) &&
      record.kind == SharedExpenseKind.expense &&
      (_authority!.canViewAll || record.payerId == _authority!.accountId) &&
      _records.any(
        (value) =>
            value.id == record.id &&
            value.revision == record.revision &&
            !value.superseded,
      ) &&
      !_records.any((value) => value.replacesId == record.id);

  Future<void> correct(
    SharedExpenseLease lease,
    SharedExpenseRecord original,
    ExpenseDraft draft,
  ) async {
    final revision = _ledgerRevision;
    final members = _membersRevision;
    if (!_current(lease) ||
        revision == null ||
        members == null ||
        _pending != null ||
        _state != SharedExpenseViewState.ready ||
        !canCorrect(original) ||
        draft.currency != original.currency ||
        draft.payerId != original.payerId ||
        draft.shares.any(
          (share) => !_participants.any((value) => value.id == share.accountId),
        ) ||
        _api is! SharedExpenseCorrectionApi) {
      return;
    }
    final pending = _PendingCommand.correction(
      commandIds(),
      revision,
      draft,
      original.id,
    );
    _pending = pending;
    _set(SharedExpenseViewState.busy);
    try {
      final receipt = await (_api as SharedExpenseCorrectionApi).correct(
        lease.authority,
        expectedLedgerRevision: revision,
        expectedMembersRevision: members,
        commandId: pending.commandId,
        original: original,
        draft: draft,
      );
      if (!_current(lease)) return;
      if (!_matches(receipt, lease, pending)) {
        _pending = null;
        _set(SharedExpenseViewState.error);
        return;
      }
      await _accept(lease, receipt);
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
      await _accept(lease, receipt);
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
    _exportedRecords = const [];
    notifyListeners();
    try {
      final result = await _api.export(
        lease.authority,
        ledgerRevision: revision,
      );
      if (!_current(lease)) return;
      if (!_validHistory(result.records, lease.authority.canViewAll) ||
          result.authority != lease.authority ||
          result.ledgerRevision != revision ||
          result.balances.any(
            (balance) =>
                !lease.authority.canViewAll &&
                balance.accountId != lease.authority.accountId,
          ) ||
          result.settlements.any(
            (settlement) =>
                !lease.authority.canViewAll &&
                settlement.debtorId != lease.authority.accountId &&
                settlement.creditorId != lease.authority.accountId,
          ) ||
          result.records.any(
            (record) =>
                !lease.authority.canViewAll &&
                record.payerId != lease.authority.accountId &&
                !record.shares.any(
                  (share) => share.accountId == lease.authority.accountId,
                ),
          )) {
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
