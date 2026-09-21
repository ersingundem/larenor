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
    required this.membersRevision,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionId;
  final String routeId;
  final int membersRevision;

  factory SharedExpenseAuthority.fromJson(
    Map<String, dynamic> json, {
    required String routeId,
    required String coreId,
    required String homeId,
    required String accountId,
  }) {
    if (json.length != 6 || json['schemaVersion'] != 1) {
      throw const FormatException('invalid_authority');
    }
    String id(String key) {
      final value = json[key];
      if (!_expenseId(value)) throw const FormatException('invalid_authority');
      return value as String;
    }

    final actualCore = id('coreId');
    final actualHome = id('homeId');
    final actualAccount = id('accountId');
    final session = id('sessionId');
    final revision = json['membersRevision'];
    if (actualCore != coreId ||
        actualHome != homeId ||
        actualAccount != accountId ||
        revision is! int ||
        revision < 1 ||
        revision > 9223372036854775807) {
      throw const FormatException('authority_changed');
    }
    return SharedExpenseAuthority(
      coreId: actualCore,
      homeId: actualHome,
      accountId: actualAccount,
      sessionId: session,
      routeId: routeId,
      membersRevision: revision,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SharedExpenseAuthority &&
      other.coreId == coreId &&
      other.homeId == homeId &&
      other.accountId == accountId &&
      other.sessionId == sessionId &&
      other.routeId == routeId &&
      other.membersRevision == membersRevision;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionId,
    routeId,
    membersRevision,
  );
}

class ExpenseParticipant {
  const ExpenseParticipant({required this.id, required this.label});

  final String id;
  final String label;

  factory ExpenseParticipant.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 || !_expenseId(json['id'])) {
      throw const FormatException('invalid_participant');
    }
    final label = json['label'];
    if (label is! String || label.isEmpty || label.length > 128) {
      throw const FormatException('invalid_participant');
    }
    return ExpenseParticipant(id: json['id'] as String, label: label);
  }
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

  factory SharedExpenseRecord.fromJson(Map<String, dynamic> json) {
    if ((json.length != 8 && json.length != 9) ||
        !_expenseId(json['id']) ||
        !_expenseId(json['payerId'])) {
      throw const FormatException('invalid_expense');
    }
    final revision = json['revision'];
    final title = json['title'];
    final currency = json['currency'];
    final scale = json['currencyScale'];
    final total = json['totalMinor'];
    final rawShares = json['shares'];
    final createdAt = json['createdAt'];
    if (revision is! int ||
        revision < 1 ||
        title is! String ||
        title.isEmpty ||
        title.length > 200 ||
        currency is! String ||
        sharedExpenseCurrencyScales[currency] != scale ||
        total is! int ||
        total < 1 ||
        total > 1000000000000 ||
        rawShares is! List ||
        rawShares.isEmpty ||
        rawShares.length > 32 ||
        (json.containsKey('createdAt') &&
            (createdAt is! num || !createdAt.isFinite || createdAt <= 0))) {
      throw const FormatException('invalid_expense');
    }
    final shares = <ExpenseShare>[];
    final seen = <String>{};
    for (final raw in rawShares) {
      if (raw is! Map<String, dynamic> ||
          raw.length != 2 ||
          !_expenseId(raw['accountId']) ||
          raw['amountMinor'] is! int ||
          (raw['amountMinor'] as int) < 0 ||
          !seen.add(raw['accountId'] as String)) {
        throw const FormatException('invalid_expense');
      }
      shares.add(
        ExpenseShare(
          accountId: raw['accountId'] as String,
          amountMinor: raw['amountMinor'] as int,
        ),
      );
    }
    if (shares.fold<int>(0, (sum, value) => sum + value.amountMinor) != total) {
      throw const FormatException('invalid_expense');
    }
    return SharedExpenseRecord(
      id: json['id'] as String,
      revision: revision,
      title: title,
      currency: currency,
      currencyScale: scale as int,
      totalMinor: total,
      payerId: json['payerId'] as String,
      shares: List.unmodifiable(shares),
    );
  }

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
    required this.eventId,
    required this.commandId,
    required this.ledgerRevision,
    required this.record,
  });

  final SharedExpenseAuthority authority;
  final String eventId;
  final String commandId;
  final int ledgerRevision;
  final SharedExpenseRecord record;
}

bool _expenseId(Object? value) =>
    value is String &&
    value.length == 32 &&
    RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

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
