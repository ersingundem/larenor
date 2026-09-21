import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/shared_expenses/data/shared_expense_controller.dart';
import 'package:larenor/features/shared_expenses/domain/shared_expense_models.dart';

const expenseAuthorityA = SharedExpenseAuthority(
  coreId: 'core-a',
  homeId: 'home-a',
  accountId: 'ada',
  sessionId: 'session-a',
  routeId: 'expenses-a',
  membersRevision: 9,
);
const expenseAuthorityB = SharedExpenseAuthority(
  coreId: 'core-b',
  homeId: 'home-b',
  accountId: 'baran',
  sessionId: 'session-b',
  routeId: 'expenses-b',
  membersRevision: 9,
);
const expenseAdminAuthority = SharedExpenseAuthority(
  coreId: 'core-a',
  homeId: 'home-a',
  accountId: 'ada',
  sessionId: 'session-a',
  routeId: 'expenses-a',
  membersRevision: 9,
  canViewAll: true,
);
const participants = [
  ExpenseParticipant(id: 'cem', label: 'Cem'),
  ExpenseParticipant(id: 'ada', label: 'Ada'),
  ExpenseParticipant(id: 'baran', label: 'Baran'),
];

SharedExpenseRecord record({
  String id = 'expense-1',
  int revision = 1,
  String payerId = 'ada',
  List<ExpenseShare> shares = const [
    ExpenseShare(accountId: 'ada', amountMinor: 5000),
    ExpenseShare(accountId: 'baran', amountMinor: 5000),
  ],
}) => SharedExpenseRecord(
  id: id,
  revision: revision,
  title: 'Ortak market',
  currency: 'TRY',
  currencyScale: 2,
  totalMinor: 10000,
  payerId: payerId,
  shares: shares,
);

class FakeSharedExpenseApi implements SharedExpenseApi {
  final snapshots = <Completer<ExpenseLedgerSnapshot>>[];
  int createCalls = 0;
  int receiptReads = 0;
  int exportReads = 0;
  bool timeoutCreate = false;
  SharedExpenseReceipt? reconciled;
  ExpenseExport? exported;

  @override
  Future<ExpenseLedgerSnapshot> snapshot(SharedExpenseAuthority authority) {
    final completer = Completer<ExpenseLedgerSnapshot>();
    snapshots.add(completer);
    return completer.future;
  }

  @override
  Future<SharedExpenseReceipt> create(
    SharedExpenseAuthority authority, {
    required int expectedLedgerRevision,
    required int expectedMembersRevision,
    required String commandId,
    required ExpenseDraft draft,
  }) async {
    createCalls++;
    if (timeoutCreate) throw TimeoutException('lost receipt');
    return SharedExpenseReceipt(
      authority: authority,
      eventId: 'event-create',
      commandId: commandId,
      ledgerRevision: expectedLedgerRevision + 1,
      record: SharedExpenseRecord.fromDraft('expense-new', draft),
    );
  }

  @override
  Future<SharedExpenseReceipt?> receipt(
    SharedExpenseAuthority authority,
    String commandId,
  ) async {
    receiptReads++;
    return reconciled;
  }

  @override
  Future<ExpenseExport> export(
    SharedExpenseAuthority authority, {
    required int ledgerRevision,
  }) async {
    exportReads++;
    return exported ?? ExpenseExport(authority, ledgerRevision, const []);
  }
}

ExpenseLedgerSnapshot snapshot(
  SharedExpenseAuthority authority, {
  int ledgerRevision = 4,
  List<SharedExpenseRecord> records = const [],
}) => ExpenseLedgerSnapshot(
  authority: authority,
  ledgerRevision: ledgerRevision,
  membersRevision: 9,
  participants: participants,
  records: records,
);

void main() {
  test('minor-unit preview rejects ambiguity and preserves every kuruş', () {
    final preview = ExpenseDraft.tryParse(
      title: 'Akşam yemeği',
      currency: 'TRY',
      amount: '100,00',
      payerId: 'ada',
      participantIds: const {'cem', 'ada', 'baran'},
    )!;
    expect(preview.totalMinor, 10000);
    expect(
      preview.shares
          .map((share) => (share.accountId, share.amountMinor))
          .toList(),
      [('ada', 3334), ('baran', 3333), ('cem', 3333)],
    );
    expect(
      preview.shares.fold(0, (sum, share) => sum + share.amountMinor),
      10000,
    );
    expect(
      ExpenseDraft.tryParse(
        title: 'Bad',
        currency: 'TRY',
        amount: '1.001',
        payerId: 'ada',
        participantIds: const {'ada'},
      ),
      isNull,
    );
    expect(
      ExpenseDraft.tryParse(
        title: 'Bad',
        currency: 'JPY',
        amount: '1.1',
        payerId: 'ada',
        participantIds: const {'ada'},
      ),
      isNull,
    );
  });

  test(
    'late snapshot cannot cross account Core home session or route',
    () async {
      final api = FakeSharedExpenseApi();
      final controller = SharedExpenseController(
        api,
        commandIds: () => 'cmd-1',
      );
      final oldLease = controller.bind(expenseAuthorityA);
      final oldLoad = controller.load(oldLease);
      final currentLease = controller.bind(expenseAuthorityB);
      api.snapshots.single.complete(
        snapshot(expenseAuthorityA, records: [record()]),
      );
      await oldLoad;
      expect(controller.authority, expenseAuthorityB);
      expect(controller.records, isEmpty);

      final currentLoad = controller.load(currentLease);
      api.snapshots.last.complete(snapshot(expenseAuthorityB));
      await currentLoad;
      expect(controller.state, SharedExpenseViewState.empty);
      expect(controller.ledgerRevision, 4);
    },
  );

  test(
    'lost create reconciles once and export stays exact and read-only',
    () async {
      final api = FakeSharedExpenseApi()..timeoutCreate = true;
      final controller = SharedExpenseController(
        api,
        commandIds: () => 'create-1',
      );
      final lease = controller.bind(expenseAuthorityA);
      final load = controller.load(lease);
      api.snapshots.single.complete(snapshot(expenseAuthorityA));
      await load;
      final draft = ExpenseDraft.tryParse(
        title: 'Market',
        currency: 'TRY',
        amount: '100.00',
        payerId: 'ada',
        participantIds: const {'ada', 'baran'},
      )!;
      await controller.create(lease, draft);
      await controller.create(lease, draft);
      expect(api.createCalls, 1, reason: 'uncertain create is never replayed');

      api.reconciled = SharedExpenseReceipt(
        authority: expenseAuthorityA,
        eventId: 'event-reconcile',
        commandId: 'create-1',
        ledgerRevision: 5,
        record: SharedExpenseRecord.fromDraft('expense-new', draft),
      );
      await controller.reconcile(lease);
      expect(api.receiptReads, 1);
      expect(controller.records.single.title, 'Market');

      api.exported = ExpenseExport(expenseAuthorityA, 5, [
        controller.records.single,
      ]);
      await controller.readExport(lease);
      expect(api.exportReads, 1);
      expect(controller.exportedRecords.single.id, 'expense-new');
      expect(api.createCalls, 1, reason: 'export is read-only');

      api.exported = ExpenseExport(expenseAuthorityA, 5, [
        record(
          id: 'foreign-expense',
          payerId: 'cem',
          shares: const [ExpenseShare(accountId: 'cem', amountMinor: 10000)],
        ),
      ]);
      await controller.readExport(lease);
      expect(controller.state, SharedExpenseViewState.error);
      expect(controller.exportedRecords, isEmpty);
    },
  );

  test(
    'admin-wide export accepts foreign records only with Core authority',
    () async {
      final api = FakeSharedExpenseApi();
      final controller = SharedExpenseController(api, commandIds: () => 'cmd');
      final lease = controller.bind(expenseAdminAuthority);
      final load = controller.load(lease);
      api.snapshots.single.complete(snapshot(expenseAdminAuthority));
      await load;
      api.exported = ExpenseExport(expenseAdminAuthority, 4, [
        record(
          id: 'foreign-expense',
          payerId: 'cem',
          shares: const [ExpenseShare(accountId: 'cem', amountMinor: 10000)],
        ),
      ]);
      await controller.readExport(lease);
      expect(controller.state, SharedExpenseViewState.empty);
      expect(controller.exportedRecords.single.id, 'foreign-expense');
    },
  );

  test(
    'foreign snapshot and failed refresh never retain prior ledger',
    () async {
      final api = FakeSharedExpenseApi();
      final controller = SharedExpenseController(api, commandIds: () => 'cmd');
      final lease = controller.bind(expenseAuthorityA);
      final first = controller.load(lease);
      api.snapshots.single.complete(
        snapshot(expenseAuthorityA, records: [record()]),
      );
      await first;
      expect(controller.records, hasLength(1));

      final refresh = controller.load(lease);
      api.snapshots.last.complete(
        snapshot(
          expenseAuthorityA,
          records: [
            record(
              id: 'foreign-expense',
              payerId: 'cem',
              shares: const [
                ExpenseShare(accountId: 'cem', amountMinor: 10000),
              ],
            ),
          ],
        ),
      );
      await refresh;
      expect(controller.state, SharedExpenseViewState.error);
      expect(controller.records, isEmpty);
    },
  );
}
