import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/power_recovery/presentation/server_power_recovery_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../server_admin_test_support.dart';

const _runId = '1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a';
const _targetStepId = '2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b';
const _localStepId = '3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c';
const _targetId = '4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d';

Map<String, dynamic> _step({
  required String stepId,
  required int sequence,
  required String action,
  required bool targeted,
  bool reconciled = false,
}) => {
  'stepId': stepId,
  'sequence': sequence,
  'action': action,
  'targetId': targeted ? _targetId : null,
  'targetKind': targeted ? 'proxmoxGuest' : null,
  'state': reconciled ? 'succeeded' : 'uncertain',
  'resultCode': reconciled
      ? 'reconciled_current_state'
      : 'reconciliation_required',
  'createdAt': 90,
  'updatedAt': reconciled ? 101 : 100,
};

Map<String, dynamic> _run({bool reconciled = false}) => {
  'runId': _runId,
  'policyRevision': 1,
  'triggerEventId': '5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e',
  'state': reconciled ? 'shuttingDown' : 'failed',
  'gateState': 'held',
  'createdAt': 90,
  'updatedAt': reconciled ? 101 : 100,
  'restoreEligibleAt': null,
  'failureCode': reconciled ? null : 'effect_failed',
  'steps': [
    _step(
      stepId: _localStepId,
      sequence: 1,
      action: 'checkpointDatabase',
      targeted: false,
    ),
    _step(
      stepId: _targetStepId,
      sequence: 2,
      action: 'shutdownTarget',
      targeted: true,
      reconciled: reconciled,
    ),
  ],
};

Map<String, dynamic> _status({bool reconciled = false}) => {
  'policy': null,
  'sourceState': 'lowBattery',
  'gateState': 'held',
  'lastSequence': 1,
  'lastObservedAt': 99,
  'activeRun': _run(reconciled: reconciled),
  'recentRuns': [_run(reconciled: reconciled)],
};

final class _Fixture extends AdminFixture {
  _Fixture({this.mismatch = false}) {
    respond = (request) async {
      final path = request.url.path;
      if (request.method == 'GET' &&
          path.endsWith('/admin/power-recovery/status')) {
        return this.json(_status(reconciled: reconciled));
      }
      if (request.method == 'POST' &&
          path.endsWith('/steps/$_targetStepId/reconcile')) {
        if (mismatch) {
          return this.json({
            'error': {'code': 'power_reconciliation_required'},
          }, 409);
        }
        reconciled = true;
        return this.json(_run(reconciled: true));
      }
      return defaultResponse(request);
    };
  }

  final bool mismatch;
  bool reconciled = false;
}

void main() {
  late _Fixture fixture;

  Future<void> mount(WidgetTester tester, {bool mismatch = false}) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = _Fixture(mismatch: mismatch);
    await fixture.account.initialize();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ServerPowerRecoveryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(
      target,
      220,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'only an uncertain target step can reconcile with the exact run CAS',
    (tester) async {
      await mount(tester);

      expect(
        find.byKey(
          const ValueKey('server-power-recovery-reconcile-$_localStepId'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey('server-power-recovery-reconcile-$_targetStepId'),
        ),
        findsOneWidget,
      );

      await tap(tester, 'server-power-recovery-reconcile-$_targetStepId');

      final requests = fixture.calls
          .where((request) => request.method == 'POST')
          .toList();
      expect(requests, hasLength(1));
      expect(
        requests.single.url.path,
        endsWith(
          '/admin/power-recovery/runs/$_runId/steps/$_targetStepId/reconcile',
        ),
      );
      expect(jsonDecode(requests.single.body), {
        'contractVersion': 1,
        'expectedUpdatedAt': 100,
      });
      expect(
        fixture.calls.any((request) => request.url.path.endsWith('/retry')),
        isFalse,
      );
      expect(
        find.byKey(
          const ValueKey('server-power-recovery-reconcile-$_targetStepId'),
        ),
        findsNothing,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, -5000));
      await tester.pumpAndSettle();
      expect(find.textContaining('Current state reconciled'), findsOneWidget);
      expect(find.textContaining(' · Verified'), findsNothing);
    },
  );

  testWidgets('state mismatch remains unresolved and is never optimistic', (
    tester,
  ) async {
    await mount(tester, mismatch: true);

    await tap(tester, 'server-power-recovery-reconcile-$_targetStepId');
    await tester.drag(find.byType(ListView).first, const Offset(0, 5000));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The current target state does not match the required outcome. '
        'The step remains unresolved.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('server-power-recovery-reconcile-$_targetStepId'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Current state reconciled'), findsNothing);
    expect(
      fixture.calls.where((request) => request.method == 'POST'),
      hasLength(1),
    );
  });
}
