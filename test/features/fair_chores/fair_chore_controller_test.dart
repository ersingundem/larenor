import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/fair_chores/data/fair_chore_controller.dart';
import 'package:larenor/features/fair_chores/domain/fair_chore_models.dart';

const authorityA = FairChoreAuthority(
  coreId: 'core-a',
  homeId: 'home-a',
  accountId: 'ada',
  sessionId: 'session-a',
  routeId: 'chores-a',
);
const authorityB = FairChoreAuthority(
  coreId: 'core-b',
  homeId: 'home-b',
  accountId: 'baran',
  sessionId: 'session-b',
  routeId: 'chores-b',
);

FairChoreTask task({
  String id = 'chore-1',
  int revision = 1,
  String assignee = 'ada',
}) => FairChoreTask(
  id: id,
  title: 'Bitkileri sula',
  revision: revision,
  assigneeId: assignee,
  dueAt: DateTime.utc(2026, 9, 22, 8),
);

class FakeFairChoreApi implements FairChoreApi {
  final listRequests = <Completer<FairChorePage>>[];
  int completeCalls = 0;
  int deferCalls = 0;
  int receiptReads = 0;
  bool timeoutCompletion = false;
  FairChoreReceipt? reconciled;
  String? commandId;

  @override
  Future<FairChorePage> list(FairChoreAuthority authority) {
    final completer = Completer<FairChorePage>();
    listRequests.add(completer);
    return completer.future;
  }

  @override
  Future<FairChoreReceipt> complete(
    FairChoreAuthority authority, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
  }) async {
    completeCalls++;
    this.commandId = commandId;
    if (timeoutCompletion) throw TimeoutException('lost receipt');
    return FairChoreReceipt(
      authority: authority,
      commandId: commandId,
      action: FairChoreAction.completed,
      task: task(revision: expectedRevision + 1, assignee: 'baran'),
    );
  }

  @override
  Future<FairChoreReceipt> defer(
    FairChoreAuthority authority, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
    required int days,
  }) async {
    deferCalls++;
    return FairChoreReceipt(
      authority: authority,
      commandId: commandId,
      action: FairChoreAction.deferred,
      task: task(revision: expectedRevision + 1),
    );
  }

  @override
  Future<FairChoreReceipt?> receipt(
    FairChoreAuthority authority,
    String commandId,
  ) async {
    receiptReads++;
    return reconciled;
  }
}

void main() {
  test(
    'late list cannot cross exact route account or Core authority',
    () async {
      final api = FakeFairChoreApi();
      final controller = FairChoreController(api, commandIds: () => 'cmd-1');
      final oldLease = controller.bind(authorityA);
      final oldLoad = controller.load(oldLease);
      final currentLease = controller.bind(authorityB);
      api.listRequests.single.complete(FairChorePage(authorityA, [task()]));
      await oldLoad;

      expect(controller.authority, authorityB);
      expect(controller.tasks, isEmpty);
      expect(controller.state, FairChoreViewState.idle);

      final currentLoad = controller.load(currentLease);
      api.listRequests.last.complete(
        FairChorePage(authorityB, [task(assignee: 'baran')]),
      );
      await currentLoad;
      expect(controller.state, FairChoreViewState.ready);
      expect(controller.tasks.single.assigneeId, 'baran');
    },
  );

  test(
    'lost completion receipt reconciles by key without command replay',
    () async {
      final api = FakeFairChoreApi()..timeoutCompletion = true;
      final controller = FairChoreController(
        api,
        commandIds: () => 'complete-1',
      );
      final lease = controller.bind(authorityA);
      final load = controller.load(lease);
      api.listRequests.single.complete(FairChorePage(authorityA, [task()]));
      await load;

      await controller.complete(lease, task());
      expect(controller.state, FairChoreViewState.uncertain);
      expect(api.completeCalls, 1);
      await controller.complete(lease, task());
      expect(
        api.completeCalls,
        1,
        reason: 'uncertain commands are never resent',
      );

      api.reconciled = FairChoreReceipt(
        authority: authorityA,
        commandId: 'complete-1',
        action: FairChoreAction.completed,
        task: task(revision: 2, assignee: 'baran'),
      );
      await controller.reconcile(lease);
      expect(api.receiptReads, 1);
      expect(controller.state, FairChoreViewState.ready);
      expect(controller.tasks.single.assigneeId, 'baran');
    },
  );

  test(
    'detach rejects late receipts and clears retained household state',
    () async {
      final api = FakeFairChoreApi();
      final controller = FairChoreController(api, commandIds: () => 'cmd-1');
      final lease = controller.bind(authorityA);
      final load = controller.load(lease);
      api.listRequests.single.complete(FairChorePage(authorityA, [task()]));
      await load;
      controller.detach(lease);

      await controller.defer(lease, task(), days: 1);
      expect(api.deferCalls, 0);
      expect(controller.authority, isNull);
      expect(controller.tasks, isEmpty);
      expect(controller.state, FairChoreViewState.detached);
    },
  );

  test(
    'receipt for another task cannot confirm an uncertain command',
    () async {
      final api = FakeFairChoreApi()..timeoutCompletion = true;
      final controller = FairChoreController(
        api,
        commandIds: () => 'complete-1',
      );
      final lease = controller.bind(authorityA);
      final load = controller.load(lease);
      api.listRequests.single.complete(FairChorePage(authorityA, [task()]));
      await load;
      await controller.complete(lease, task());
      api.reconciled = FairChoreReceipt(
        authority: authorityA,
        commandId: 'complete-1',
        action: FairChoreAction.completed,
        task: task(id: 'chore-2', revision: 2),
      );

      await controller.reconcile(lease);

      expect(controller.state, FairChoreViewState.error);
      expect(controller.tasks.single.id, 'chore-1');
      expect(controller.tasks.single.revision, 1);
    },
  );
}
