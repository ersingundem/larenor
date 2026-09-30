import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/fair_chores/data/fair_chore_api.dart';
import 'package:larenor/features/fair_chores/data/fair_chore_controller.dart';
import 'package:larenor/features/fair_chores/domain/fair_chore_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

final class _LostCompletionApi implements FairChoreCommandApi {
  _LostCompletionApi(this.delegate, {required this.loseFirstCompletion});

  final FairChoreAccountApi delegate;
  bool loseFirstCompletion;
  int completionWrites = 0;

  @override
  Future<FairChorePage> list(FairChoreAuthority authority) =>
      delegate.list(authority);

  @override
  Future<FairChoreReceipt> create(
    FairChoreAuthority authority, {
    required String commandId,
    required String title,
    required String timezone,
    required int intervalDays,
    required DateTime dueAt,
  }) => delegate.create(
    authority,
    commandId: commandId,
    title: title,
    timezone: timezone,
    intervalDays: intervalDays,
    dueAt: dueAt,
  );

  @override
  Future<FairChoreReceipt> complete(
    FairChoreAuthority authority, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
  }) async {
    final receipt = await delegate.complete(
      authority,
      taskId: taskId,
      expectedRevision: expectedRevision,
      commandId: commandId,
    );
    completionWrites++;
    if (loseFirstCompletion) {
      loseFirstCompletion = false;
      throw TimeoutException('synthetic response loss after Core commit');
    }
    return receipt;
  }

  @override
  Future<FairChoreReceipt> defer(
    FairChoreAuthority authority, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
    required int days,
  }) => delegate.defer(
    authority,
    taskId: taskId,
    expectedRevision: expectedRevision,
    commandId: commandId,
    days: days,
  );

  @override
  Future<FairChoreReceipt> skip(
    FairChoreAuthority authority, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
  }) => delegate.skip(
    authority,
    taskId: taskId,
    expectedRevision: expectedRevision,
    commandId: commandId,
  );

  @override
  Future<FairChoreReceipt?> receipt(
    FairChoreAuthority authority,
    String commandId,
  ) => delegate.receipt(authority, commandId);
}

void main() {
  final url = Platform.environment['LARENOR_CHORE_CORE_URL'];
  final phase = Platform.environment['LARENOR_CHORE_PHASE'];
  final statePath = Platform.environment['LARENOR_CHORE_STATE_FILE'];

  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client rotates chores, reconciles a lost ACK, and survives departure',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Fair chore acceptance',
      );
      expect(account.failure, isNull);
      var current = true;
      final production = await FairChoreAccountApi.connect(
        account: account,
        context: account.session!.context!,
        routeId: 'f36-normal-core',
        isCurrent: () => current,
      );
      addTearDown(production.close);
      final api = _LostCompletionApi(
        production,
        loseFirstCompletion: phase == 'create',
      );
      final ids =
          (phase == 'create'
                  ? ['1' * 32, '2' * 32, '3' * 32]
                  : ['4' * 32, '5' * 32])
              .iterator;
      final controller = FairChoreController(
        api,
        commandIds: () {
          expect(ids.moveNext(), isTrue);
          return ids.current;
        },
      );
      addTearDown(controller.dispose);
      final lease = controller.bind(production.authority);
      await controller.load(lease);
      final state = File(statePath!);

      if (phase == 'create') {
        expect(controller.state, FairChoreViewState.empty);
        await controller.create(
          lease,
          title: 'Clean kitchen',
          timezone: 'Europe/Berlin',
          intervalDays: 60,
          dueAt: DateTime.utc(2026, 9, 6, 12),
        );
        expect(controller.state, FairChoreViewState.ready);
        final created = controller.tasks.single;
        expect(created.revision, 1);
        expect(created.assigneeId, production.authority.accountId);
        final initialDue = created.dueAt;

        await controller.defer(lease, created, days: 1);
        final deferred = controller.tasks.single;
        expect(deferred.revision, 2);
        expect(deferred.dueAt.difference(initialDue), const Duration(days: 1));

        await controller.complete(lease, deferred);
        expect(controller.state, FairChoreViewState.uncertain);
        expect(api.completionWrites, 1);
        await controller.reconcile(lease);
        expect(controller.state, FairChoreViewState.ready);
        expect(api.completionWrites, 1);
        final completed = controller.tasks.single;
        expect(completed.revision, 3);
        expect(completed.assigneeId, isNot(production.authority.accountId));
        // 2026-09-05 14:00 CEST + 60 local days = 2026-11-04 14:00 CET.
        expect(completed.dueAt, DateTime.utc(2026, 11, 4, 13));
        await state.writeAsString(
          jsonEncode({
            'taskId': completed.id,
            'departedId': completed.assigneeId,
          }),
        );
      } else {
        expect(phase, 'restart');
        final proof = jsonDecode(await state.readAsString());
        expect(controller.state, FairChoreViewState.ready);
        final departed = controller.tasks.single;
        expect(departed.id, proof['taskId']);
        expect(departed.revision, 3);
        expect(departed.assigneeId, proof['departedId']);
        expect(departed.memberOrder, hasLength(1));
        expect(departed.permissions.complete, isFalse);
        expect(departed.permissions.skip, isTrue);

        await controller.skip(lease, departed);
        final handedOff = controller.tasks.single;
        expect(handedOff.revision, 4);
        expect(handedOff.assigneeId, production.authority.accountId);
        await controller.complete(lease, handedOff);
        final repeated = controller.tasks.single;
        expect(repeated.revision, 5);
        expect(repeated.assigneeId, production.authority.accountId);
        expect(api.completionWrites, 1);
      }

      current = false;
      await expectLater(
        production.list(production.authority),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'authority_changed',
          ),
        ),
      );
    },
    skip: url == null || phase == null || statePath == null
        ? 'Requires the isolated normal Core TCP runner'
        : false,
  );
}
