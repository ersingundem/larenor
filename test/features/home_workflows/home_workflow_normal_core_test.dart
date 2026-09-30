import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/home_workflows/data/home_workflow_api.dart';
import 'package:larenor/features/home_workflows/domain/home_workflow_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map) throw const FormatException('invalid_fixture');
  return value.map((key, child) => MapEntry(key as String, child));
}

void main() {
  final coreUrl = Platform.environment['LARENOR_F05_CORE_URL'];
  final phase = Platform.environment['LARENOR_F05_PHASE'];
  final fixturePath = Platform.environment['LARENOR_F05_FIXTURE'];

  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client completes and reconciles a durable workflow across restart',
    () async {
      final file = File(fixturePath!);
      final fixture = _object(jsonDecode(await file.readAsString()));
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'F05 workflow acceptance',
      );
      expect(account.failure, isNull);
      final context = account.context!;
      final target = HomeResourceRecord.fromJson(
        fixture['resource'],
        expectedContext: context,
      );
      var current = true;
      final api = await HomeWorkflowAccountApi.connect(
        account: account,
        context: context,
        isCurrent: () => current,
      );
      addTearDown(() {
        current = false;
        api.close();
      });

      const requestId = 'a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0';
      const decisionId = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
      const title = 'Turn on the owned switch';
      if (phase == 'create-approve') {
        final created = await api.create(
          requestId: requestId,
          title: title,
          deadlineSeconds: 300,
          target: target,
          action: HomeWorkflowAction.turnOn,
        );
        expect(created.state, HomeWorkflowState.waitingDecision);
        expect(
          created.decisionRequired,
          HomeWorkflowDecisionRequired.approveEffect,
        );
        expect(created.effectState, HomeWorkflowEffectState.notStarted);
        final completed = await api.decide(
          workflow: created,
          decisionId: decisionId,
          decision: HomeWorkflowDecision.approve,
        );
        expect(completed.revision, 2);
        expect(completed.state, HomeWorkflowState.completed);
        expect(completed.effectState, HomeWorkflowEffectState.accepted);
        expect(
          completed.reconciliationResult,
          HomeWorkflowReconciliationResult.effectApplied,
        );
        await file.writeAsString(
          jsonEncode({...fixture, 'workflowId': completed.id}),
          flush: true,
        );
      } else {
        expect(phase, 'restart');
        final workflowId = fixture['workflowId'] as String;
        final retained = await api.detail(workflowId);
        expect(retained.state, HomeWorkflowState.completed);
        expect(retained.effectState, HomeWorkflowEffectState.accepted);
        final page = await api.list();
        expect(page.workflows.map((value) => value.id), contains(workflowId));

        final replayed = await api.create(
          requestId: requestId,
          title: title,
          deadlineSeconds: 300,
          target: target,
          action: HomeWorkflowAction.turnOn,
        );
        expect(replayed.id, workflowId);
        expect(replayed.revision, 2);
        expect(replayed.state, HomeWorkflowState.completed);

        // Reconcile an acknowledgement lost after the first Core committed the
        // decision. This exact operation replay must return the durable result
        // and must not invoke Home Assistant again.
        await account.withSession((transport, session) async {
          final raw = await transport.request(
            'POST',
            '/home-workflows/${context.coreId}/${context.homeId}/'
                '$workflowId/decisions',
            token: session.accessToken,
            body: {
              'schemaVersion': 1,
              'decisionId': decisionId,
              'expectedRevision': 1,
              'decision': 'approve',
            },
          );
          final replay = _object(raw?['workflow']);
          expect(replay['id'], workflowId);
          expect(replay['revision'], 2);
          expect(replay['state'], 'completed');
          expect(replay['effectState'], 'accepted');
        });

        final cancellable = await api.create(
          requestId: 'c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0',
          title: 'Cancel before provider dispatch',
          deadlineSeconds: 300,
          target: target,
          action: HomeWorkflowAction.turnOff,
        );
        final cancelled = await api.decide(
          workflow: cancellable,
          decisionId: 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0',
          decision: HomeWorkflowDecision.cancel,
        );
        expect(cancelled.state, HomeWorkflowState.cancelled);
        expect(cancelled.effectState, HomeWorkflowEffectState.notStarted);
      }
    },
    skip: coreUrl == null || phase == null || fixturePath == null
        ? 'Requires the isolated F05 normal Core runner'
        : false,
  );
}
