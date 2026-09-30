import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/shared_expenses/data/shared_expense_api.dart';
import 'package:larenor/features/shared_expenses/data/shared_expense_controller.dart';
import 'package:larenor/features/shared_expenses/domain/shared_expense_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? session) async {}
}

void main() {
  final url = Platform.environment['LARENOR_EXPENSE_CORE_URL'];
  final phase = Platform.environment['LARENOR_EXPENSE_PHASE'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'real Client corrects immutable expenses and payments across Core restart',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Expense acceptance',
      );
      expect(account.failure, isNull);
      var current = true;
      final api = await SharedExpenseAccountApi.connect(
        account: account,
        context: account.session!.context!,
        routeId: 'expense-proof',
        isCurrent: () => current,
      );
      addTearDown(api.close);
      final ids =
          (phase == 'create' ? ['1' * 32, '2' * 32, '3' * 32] : ['4' * 32])
              .iterator;
      final controller = SharedExpenseController(
        api,
        commandIds: () {
          expect(ids.moveNext(), isTrue);
          return ids.current;
        },
      );
      addTearDown(controller.dispose);
      final lease = controller.bind(api.authority);
      await controller.load(lease);
      final payer = account.session!.user.id;
      final member = controller.participants
          .singleWhere((p) => p.id != payer)
          .id;
      final file = File(Platform.environment['LARENOR_EXPENSE_STATE_FILE']!);
      ExpenseDraft draft(String title, String amount) => ExpenseDraft.tryParse(
        title: title,
        currency: 'TRY',
        amount: amount,
        payerId: payer,
        participantIds: {payer, member},
      )!;
      if (phase == 'create') {
        await controller.create(lease, draft('Original bill', '10.01'));
        expect(controller.state, SharedExpenseViewState.ready);
        final original = controller.records.single;
        await controller.correct(
          lease,
          original,
          draft('Corrected bill', '20.01'),
        );
        expect(controller.state, SharedExpenseViewState.ready);
        expect(controller.ledgerRevision, 3);
        expect(
          controller.records.singleWhere((v) => v.id == original.id).totalMinor,
          1001,
        );
        final correction = controller.records.singleWhere(
          (v) => v.replacesId == original.id,
        );
        expect(correction.totalMinor, 2001);
        expect(controller.canCorrect(original), isFalse);
        final replay = await api.correct(
          api.authority,
          expectedLedgerRevision: 2,
          expectedMembersRevision: api.authority.membersRevision,
          commandId: '2' * 32,
          original: original,
          draft: draft('Corrected bill', '20.01'),
        );
        expect(replay.record.id, correction.id);
        final settlement = controller.settlements.single;
        await controller.createPayment(
          lease,
          ExpensePaymentDraft.tryParse(
            currency: 'TRY',
            amount: '5.00',
            payerId: member,
            recipientId: payer,
            maximumMinor: settlement.amountMinor,
          )!,
        );
        expect(controller.ledgerRevision, 4);
        expect(
          controller.settlements.single.amountMinor,
          settlement.amountMinor - 500,
        );
        await controller.readExport(lease);
        expect(controller.exportText, contains(original.id));
        expect(controller.exportText, contains(correction.id));
        expect(controller.exportText, contains('replaces_id'));
        await file.writeAsString(
          jsonEncode({'original': original.id, 'correction': correction.id}),
        );
      } else {
        final proof =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(controller.ledgerRevision, 4);
        expect(controller.records.length, 3);
        final original = controller.records.singleWhere(
          (v) => v.id == proof['original'],
        );
        final correction = controller.records.singleWhere(
          (v) => v.id == proof['correction'],
        );
        expect(original.totalMinor, 1001);
        expect(correction.replacesId, original.id);
        final replay = await api.correct(
          api.authority,
          expectedLedgerRevision: 2,
          expectedMembersRevision: api.authority.membersRevision,
          commandId: '2' * 32,
          original: original,
          draft: draft('Corrected bill', '20.01'),
        );
        expect(replay.record.id, correction.id);
        await controller.correct(
          lease,
          correction,
          draft('Corrected again', '30.01'),
        );
        expect(controller.state, SharedExpenseViewState.ready);
        expect(controller.ledgerRevision, 5);
        expect(controller.records.length, 4);
        final active = controller.records.singleWhere(
          (v) => v.replacesId == correction.id,
        );
        final owed = active.shares
            .singleWhere((v) => v.accountId == member)
            .amountMinor;
        expect(controller.settlements.single.amountMinor, owed - 500);
        current = false;
        await expectLater(api.snapshot(api.authority), throwsA(anything));
      }
    },
    skip: url == null || phase == null,
  );
}
