const sharedExpenseCurrencyScales = <String, int>{
  'EUR': 2,
  'GBP': 2,
  'JPY': 0,
  'TRY': 2,
  'USD': 2,
};

class SharedExpenseAuthority {
  const SharedExpenseAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionId,
    required this.routeId,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionId;
  final String routeId;

  @override
  bool operator ==(Object other) =>
      other is SharedExpenseAuthority &&
      other.coreId == coreId &&
      other.homeId == homeId &&
      other.accountId == accountId &&
      other.sessionId == sessionId &&
      other.routeId == routeId;

  @override
  int get hashCode =>
      Object.hash(coreId, homeId, accountId, sessionId, routeId);
}

class ExpenseParticipant {
  const ExpenseParticipant({required this.id, required this.label});

  final String id;
  final String label;
}

class ExpenseShare {
  const ExpenseShare({required this.accountId, required this.amountMinor});

  final String accountId;
  final int amountMinor;
}

class ExpenseDraft {
  const ExpenseDraft._({
    required this.title,
    required this.currency,
    required this.currencyScale,
    required this.totalMinor,
    required this.payerId,
    required this.shares,
  });

  final String title;
  final String currency;
  final int currencyScale;
  final int totalMinor;
  final String payerId;
  final List<ExpenseShare> shares;

  static ExpenseDraft? tryParse({
    required String title,
    required String currency,
    required String amount,
    required String payerId,
    required Set<String> participantIds,
  }) {
    final scale = sharedExpenseCurrencyScales[currency];
    final cleanTitle = title.trim();
    if (scale == null ||
        cleanTitle.isEmpty ||
        cleanTitle.length > 200 ||
        payerId.isEmpty ||
        participantIds.isEmpty ||
        participantIds.length > 32 ||
        participantIds.any((id) => id.isEmpty || id.length > 128)) {
      return null;
    }
    final normalized = amount.trim().replaceAll(',', '.');
    final expression = scale == 0
        ? RegExp(r'^[0-9]{1,12}$')
        : RegExp('^[0-9]{1,10}(?:\\.[0-9]{1,$scale})?\$');
    if (!expression.hasMatch(normalized)) return null;
    final parts = normalized.split('.');
    final factor = _pow10(scale);
    final whole = int.tryParse(parts.first);
    if (whole == null) return null;
    final fraction = scale == 0 || parts.length == 1
        ? 0
        : int.parse(parts[1].padRight(scale, '0'));
    final total = whole * factor + fraction;
    if (total < 1 || total > 1000000000000) return null;
    final accounts = participantIds.toList()..sort();
    final base = total ~/ accounts.length;
    final remainder = total % accounts.length;
    return ExpenseDraft._(
      title: cleanTitle,
      currency: currency,
      currencyScale: scale,
      totalMinor: total,
      payerId: payerId,
      shares: List.unmodifiable([
        for (var index = 0; index < accounts.length; index++)
          ExpenseShare(
            accountId: accounts[index],
            amountMinor: base + (index < remainder ? 1 : 0),
          ),
      ]),
    );
  }
}

int _pow10(int scale) {
  var result = 1;
  for (var index = 0; index < scale; index++) {
    result *= 10;
  }
  return result;
}

String formatExpenseMinor(int value, int scale, {String separator = '.'}) {
  if (scale == 0) return value.toString();
  final factor = _pow10(scale);
  final whole = value ~/ factor;
  final fraction = (value % factor).toString().padLeft(scale, '0');
  return '$whole$separator$fraction';
}

class SharedExpenseRecord {
  const SharedExpenseRecord({
    required this.id,
    required this.revision,
    required this.title,
    required this.currency,
    required this.currencyScale,
    required this.totalMinor,
    required this.payerId,
    required this.shares,
  });

  factory SharedExpenseRecord.fromDraft(String id, ExpenseDraft draft) =>
      SharedExpenseRecord(
        id: id,
        revision: 1,
        title: draft.title,
        currency: draft.currency,
        currencyScale: draft.currencyScale,
        totalMinor: draft.totalMinor,
        payerId: draft.payerId,
        shares: draft.shares,
      );

  final String id;
  final int revision;
  final String title;
  final String currency;
  final int currencyScale;
  final int totalMinor;
  final String payerId;
  final List<ExpenseShare> shares;

  bool matchesDraft(ExpenseDraft draft) {
    if (revision != 1 ||
        title != draft.title ||
        currency != draft.currency ||
        currencyScale != draft.currencyScale ||
        totalMinor != draft.totalMinor ||
        payerId != draft.payerId ||
        shares.length != draft.shares.length) {
      return false;
    }
    for (var index = 0; index < shares.length; index++) {
      if (shares[index].accountId != draft.shares[index].accountId ||
          shares[index].amountMinor != draft.shares[index].amountMinor) {
        return false;
      }
    }
    return true;
  }
}

class ExpenseLedgerSnapshot {
  ExpenseLedgerSnapshot({
    required this.authority,
    required this.ledgerRevision,
    required this.membersRevision,
    required List<ExpenseParticipant> participants,
    required List<SharedExpenseRecord> records,
  }) : participants = List.unmodifiable(participants),
       records = List.unmodifiable(records);

  final SharedExpenseAuthority authority;
  final int ledgerRevision;
  final int membersRevision;
  final List<ExpenseParticipant> participants;
  final List<SharedExpenseRecord> records;
}

class SharedExpenseReceipt {
  const SharedExpenseReceipt({
    required this.authority,
    required this.commandId,
    required this.ledgerRevision,
    required this.record,
  });

  final SharedExpenseAuthority authority;
  final String commandId;
  final int ledgerRevision;
  final SharedExpenseRecord record;
}

class ExpenseExport {
  ExpenseExport(
    this.authority,
    this.ledgerRevision,
    List<SharedExpenseRecord> records,
  ) : records = List.unmodifiable(records);

  final SharedExpenseAuthority authority;
  final int ledgerRevision;
  final List<SharedExpenseRecord> records;
}

abstract interface class SharedExpenseApi {
  Future<ExpenseLedgerSnapshot> snapshot(SharedExpenseAuthority authority);

  Future<SharedExpenseReceipt> create(
    SharedExpenseAuthority authority, {
    required int expectedLedgerRevision,
    required int expectedMembersRevision,
    required String commandId,
    required ExpenseDraft draft,
  });

  Future<SharedExpenseReceipt?> receipt(
    SharedExpenseAuthority authority,
    String commandId,
  );

  Future<ExpenseExport> export(
    SharedExpenseAuthority authority, {
    required int ledgerRevision,
  });
}
