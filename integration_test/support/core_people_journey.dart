import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';

import 'app_harness.dart';
import 'single_element_ready.dart';
import 'synthetic_core_account.dart';
import 'synthetic_core_people_account.dart';

/// Registered in the existing Android target after its original ten journeys.
/// Only the opt-in account fixture changes; app navigation and HTTP are real.
void registerCorePeopleJourney() {
  testWidgets(
    'Core people → explicit member list → empty refresh → fresh route read',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE core_people.begin');
      final app = await AppHarness.start(connected: true, coreSource: true);
      // No request or widget is started before this explicit fixture selection.
      // Default AppHarness and all older journeys keep their account behavior.
      final core = SyntheticCorePeopleAccount();
      app.server.coreAccount = core;
      Finder key(String value) => find.byKey(ValueKey(value));
      Future<void> press(String value) => tapVisible(tester, key(value));
      final first = key('home-people-row-${'1' * 32}');
      final second = key('home-people-row-${'2' * 32}');

      void noHomeEffects() {
        expect(app.server.requests, 0);
        expect(app.server.acceptedActions, isEmpty);
        expect(app.server.rejectedLogins, 0);
        expect(app.server.rejectedWrites, 0);
        expect(app.server.subscriptions, 0);
        expect(app.wsClientsCreated, 0);
        expect(core.rejectedRequests, 0);
        expect(core.injectedAckLosses, 0);
        expect(app.network.blocked, 0);
        expect(
          core.requestedPeopleScopes.every(
            (scope) => scope == (core.coreId, core.homeId),
          ),
          isTrue,
        );
      }

      void memberControlsOnly() {
        expect(key('home-people-manage'), findsNothing);
        expect(key('home-people-admin'), findsNothing);
        expect(key('home-people-create'), findsNothing);
        expect(key('home-people-grant-save'), findsNothing);
      }

      try {
        await app.mount(tester);
        await waitFor(tester, find.byType(CoreHomeStatusScreen));
        expect(core.peopleReads, 0);
        await tapVisible(tester, find.text('Manage Core account'));
        await waitFor(tester, find.text('Unlock'));
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.byType(ServerConnectionScreen));
        await tester.enterText(key('server-url'), app.server.baseUrl);
        await tester.enterText(
          key('server-username'),
          SyntheticCoreAccount.username,
        );
        await tester.enterText(
          key('server-password'),
          SyntheticCoreAccount.password,
        );
        await press('server-sign-in');
        await waitFor(
          tester,
          find.text('The Core account and home are verified.'),
        );
        expect(core.user['role'], 'member');
        expect(core.logins, 1);
        expect(core.contextReads, 1);
        expect(
          core.peopleReads,
          0,
          reason: 'Core home does not load people automatically',
        );
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people.account_verified');

        await press('home-people-entry');
        await waitFor(tester, key('home-people-list'));
        await waitFor(tester, first);
        await waitFor(tester, second);
        expect(find.text('Deniz Öztürk'), findsOneWidget);
        expect(find.text('🌿' * 80), findsOneWidget);
        expect(core.peopleReads, 1);
        memberControlsOnly();
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people.member_visible');

        core.view = SyntheticCorePeopleView.empty;
        await press('home-people-refresh');
        await waitFor(tester, key('home-people-empty'));
        expect(first, findsNothing);
        expect(second, findsNothing);
        expect(find.text('Deniz Öztürk'), findsNothing);
        expect(find.text('🌿' * 80), findsNothing);
        expect(core.peopleReads, 2);
        memberControlsOnly();
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people.empty_refreshed');

        await press('home-people-back');
        await corePeopleJourneyWaitForReturn(tester);
        expect(key('home-people-list'), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          core.peopleReads,
          2,
          reason: 'Returning to Core does not reopen the list',
        );
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people.return_no_read');

        core.view = SyntheticCorePeopleView.member;
        await press('home-people-entry');
        await waitFor(tester, first);
        await waitFor(tester, second);
        expect(find.text('Deniz Öztürk'), findsOneWidget);
        expect(key('home-people-empty'), findsNothing);
        expect(
          core.peopleReads,
          3,
          reason: 'A new route obtains a fresh scoped response',
        );
        memberControlsOnly();
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people.fresh_read');
      } finally {
        debugPrint('LARENOR_E2E_PHASE core_people.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE core_people.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// Wait for the journey's existing Core route readiness predicate.
Future<void> corePeopleJourneyWaitForReturn(WidgetTester tester) => waitUntil(
  tester,
  () => singleElementReady(
    find.byType(CoreHomeStatusScreen),
    (element) =>
        ModalRoute.of(element)?.isCurrent == true &&
        TickerMode.valuesOf(element).enabled,
  ),
);
