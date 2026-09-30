import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/shared_expenses/data/shared_expense_controller.dart';
import 'package:larenor/features/shared_expenses/domain/shared_expense_models.dart';
import 'package:larenor/features/shared_expenses/presentation/shared_expense_screen.dart';

import 'shared_expense_controller_test.dart';
import 'shared_expense_screen_test.dart';

final class _CorrectionApi extends FakeSharedExpenseApi
    implements SharedExpenseCorrectionApi {
  int corrections = 0;
  SharedExpenseRecord? result;
  @override
  Future<SharedExpenseReceipt> correct(
    SharedExpenseAuthority authority, {
    required int expectedLedgerRevision,
    required int expectedMembersRevision,
    required String commandId,
    required SharedExpenseRecord original,
    required ExpenseDraft draft,
  }) async {
    corrections++;
    expect(original.id, 'expense-1');
    expect(draft.payerId, original.payerId);
    expect(draft.currency, original.currency);
    result = SharedExpenseRecord(
      id: 'correction-1',
      revision: 1,
      title: draft.title,
      currency: draft.currency,
      currencyScale: draft.currencyScale,
      totalMinor: draft.totalMinor,
      payerId: draft.payerId,
      shares: draft.shares,
      replacesId: original.id,
    );
    return SharedExpenseReceipt(
      authority: authority,
      eventId: 'event-correction',
      commandId: commandId,
      ledgerRevision: expectedLedgerRevision + 1,
      record: result!,
    );
  }
}

void main() {
  testWidgets(
    'EN/TR correction keeps immutable history and locked payer/currency',
    (tester) async {
      for (final sample in [
        (const Size(600, 900), SharedExpenseStrings.tr),
        (const Size(1200, 800), SharedExpenseStrings.en),
      ]) {
        final api = _CorrectionApi();
        await pumpExpenseScreen(
          tester,
          size: sample.$1,
          strings: sample.$2,
          api: api,
        );
        final edit = find.byKey(const ValueKey('expense-edit-expense-1'));
        await tester.ensureVisible(edit);
        await tester.tap(edit);
        await tester.pumpAndSettle();
        expect(find.text(sample.$2.correctionNote), findsOneWidget);
        expect(
          tester
              .widget<CupertinoTextField>(
                find.byKey(const ValueKey('expense-amount')),
              )
              .controller!
              .text,
          '100${sample.$2.decimalSeparator}00',
        );
        final currency = find.widgetWithText(CupertinoButton, 'EUR');
        expect(tester.widget<CupertinoButton>(currency).onPressed, isNull);
        await tester.enterText(
          find.byKey(const ValueKey('expense-title')),
          'Corrected',
        );
        await tester.enterText(
          find.byKey(const ValueKey('expense-amount')),
          '200.01',
        );
        await tester.pump();
        final submit = find.byKey(const ValueKey('expense-create'));
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pump();
        expect(api.corrections, 1);
        api.snapshots.last.complete(
          snapshot(
            expenseAuthorityA,
            ledgerRevision: 5,
            records: [
              SharedExpenseRecord(
                id: record().id,
                revision: 1,
                title: record().title,
                currency: 'TRY',
                currencyScale: 2,
                totalMinor: 10000,
                payerId: 'ada',
                shares: record().shares,
                superseded: true,
              ),
              api.result!,
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(sample.$2.corrected), findsOneWidget);
        expect(
          find.byKey(const ValueKey('expense-edit-expense-1')),
          findsNothing,
        );
        expect(api.result!.totalMinor, 20001);
        expect(api.result!.replacesId, 'expense-1');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets(
    'departed split participant is explicit and removable before correction',
    (tester) async {
      final api = _CorrectionApi();
      await pumpExpenseScreen(
        tester,
        size: const Size(600, 900),
        strings: SharedExpenseStrings.en,
        api: api,
        initialRecords: [
          record(
            shares: const [
              ExpenseShare(accountId: 'ada', amountMinor: 5000),
              ExpenseShare(accountId: 'departed', amountMinor: 5000),
            ],
          ),
        ],
      );
      final edit = find.byKey(const ValueKey('expense-edit-expense-1'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(
        find.text(SharedExpenseStrings.en.unavailableParticipant),
        findsOneWidget,
      );
      final submit = find.byKey(const ValueKey('expense-create'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      expect(api.corrections, 0);
      final remove = find.byKey(
        const ValueKey('expense-remove-unavailable-departed'),
      );
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pump();
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      expect(api.corrections, 1);
      expect(api.result!.shares.map((value) => value.accountId), ['ada']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'inactive immutable payer has a clear reason and no edit action',
    (tester) async {
      await pumpExpenseScreen(
        tester,
        size: const Size(1200, 800),
        strings: SharedExpenseStrings.tr,
        api: _CorrectionApi(),
        authority: expenseAdminAuthority,
        initialRecords: [record(payerId: 'departed')],
      );
      expect(find.text(SharedExpenseStrings.tr.inactivePayer), findsOneWidget);
      expect(
        find.byKey(const ValueKey('expense-edit-expense-1')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('admin history rejects hidden predecessors, branches, cycles and false superseded flags', () async {
    SharedExpenseRecord item(
      String id, {
      String? replaces,
      bool superseded = false,
    }) => SharedExpenseRecord(
      id: id,
      revision: 1,
      title: 'Bill',
      currency: 'TRY',
      currencyScale: 2,
      totalMinor: 10000,
      payerId: 'ada',
      shares: record().shares,
      replacesId: replaces,
      superseded: superseded,
    );
    final cases = [
      [item('correction', replaces: 'missing')],
      [
        item('old', superseded: true),
        item('a', replaces: 'old'),
        item('b', replaces: 'old'),
      ],
      [
        item('a', replaces: 'b', superseded: true),
        item('b', replaces: 'a', superseded: true),
      ],
      [item('old'), item('new', replaces: 'old')],
    ];
    for (final records in cases) {
      final api = _CorrectionApi();
      final controller = SharedExpenseController(api, commandIds: () => 'cmd');
      final lease = controller.bind(expenseAdminAuthority);
      final loading = controller.load(lease);
      api.snapshots.single.complete(
        snapshot(expenseAdminAuthority, records: records),
      );
      await loading;
      expect(controller.state, SharedExpenseViewState.error);
      expect(controller.records, isEmpty);
      controller.dispose();
    }
    final api = _CorrectionApi();
    final controller = SharedExpenseController(api, commandIds: () => 'cmd');
    final lease = controller.bind(expenseAuthorityA);
    final records = [item('correction', replaces: 'filtered-predecessor')];
    final loading = controller.load(lease);
    api.snapshots.single.complete(
      snapshot(expenseAuthorityA, records: records),
    );
    await loading;
    expect(controller.state, SharedExpenseViewState.ready);
    controller.dispose();
  });
}
