import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';

import 'app_harness.dart';
import 'single_element_ready.dart';
import 'synthetic_core_account.dart';
import 'synthetic_core_people_admin_account.dart';

/// Only this new journey's controls: bounded vertical discovery, then actual
/// single, current, enabled native button readiness. No callback invocation.
Future<void> tapPeopleAdminControl(WidgetTester tester, String value) async {
  final target = find.byKey(ValueKey(value));
  List<Finder> currentPages() =>
      ['home-person-grants-screen', 'home-people-admin', 'home-people-list']
          .map((name) => find.byKey(ValueKey(name)))
          .where(
            (page) => singleElementReady(
              page,
              (element) => ModalRoute.of(element)?.isCurrent == true,
            ),
          )
          .toList();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 100));
  await waitUntil(
    tester,
    () => target.evaluate().isNotEmpty || currentPages().isNotEmpty,
  );
  if (target.evaluate().isEmpty) {
    final pages = currentPages();
    expect(pages, hasLength(1));
    final viewport = find.descendant(
      of: pages.single,
      matching: find.byType(CustomScrollView),
    );
    expect(viewport, findsOneWidget);
    final vertical = find.descendant(
      of: viewport,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            (widget.axisDirection == AxisDirection.down ||
                widget.axisDirection == AxisDirection.up),
      ),
    );
    expect(vertical, findsOneWidget);
    tester.state<ScrollableState>(vertical).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      target,
      320,
      scrollable: vertical,
      maxScrolls: 40,
    );
  }
  bool ready() => singleElementReady(target, (element) {
    if (ModalRoute.of(element)?.isCurrent != true ||
        !TickerMode.valuesOf(element).enabled) {
      return false;
    }
    final native = element.widget is CupertinoButton
        ? target
        : find.descendant(of: target, matching: find.byType(CupertinoButton));
    return singleElementReady(
      native,
      (button) => (button.widget as CupertinoButton).onPressed != null,
    );
  });
  await waitUntil(tester, ready);
  await tester.ensureVisible(target);
  // A layout frame must follow scrolling before testing/tapping its new bounds.
  await tester.pump(const Duration(milliseconds: 350));
  await waitUntil(tester, ready);
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 350));
}

/// Positive, real Android UI/loopback HTTP journey; not Server auth/SQLite proof.
void registerCorePeopleAdminJourney() {
  testWidgets(
    'Core people admin → PIN metadata → ACL → cancelled and confirmed delete',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE core_people_admin.begin');
      final app = await AppHarness.start(connected: true, coreSource: true);
      final core = SyntheticCorePeopleAdminAccount();
      app.server.coreAccount = core;
      Finder key(String value) => find.byKey(ValueKey(value));
      Future<void> press(String value) => tapPeopleAdminControl(tester, value);
      void noHomeEffects() {
        expect(app.server.requests, 0);
        expect(app.server.acceptedActions, isEmpty);
        expect(app.server.rejectedLogins, 0);
        expect(app.server.rejectedWrites, 0);
        expect(app.server.subscriptions, 0);
        expect(app.wsClientsCreated, 0);
        expect(app.network.blocked, 0);
        expect(core.rejectedRequests, 0);
        expect(core.injectedAckLosses, 0);
      }

      Future<void> unlock() async {
        await waitFor(tester, find.text('Unlock'));
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
      }

      try {
        await app.mount(tester);
        await waitFor(tester, find.byType(CoreHomeStatusScreen));
        expect(core.peopleReads, 0);
        await tapVisible(tester, find.text('Manage Core account'));
        await unlock();
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
        expect(core.logins, 1);
        expect(core.contextReads, 1);
        expect(core.user['role'], 'admin');
        expect(core.peopleReads, 0);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.account_verified');
        await press('home-people-entry');
        await waitFor(tester, key('home-people-empty'));
        await press('home-people-manage');
        expect(core.mutations, isEmpty);
        await unlock();
        await waitFor(tester, key('home-people-admin'));
        await waitFor(tester, key('home-people-empty'));
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.admin_pin_verified');

        final reads = core.peopleReads,
            id = core.firstId,
            subject = core.subjectId;
        await press('home-people-create');
        await waitFor(tester, key('home-people-label'));
        await tester.enterText(key('home-people-label'), 'Deniz Öztürk');
        await tester.enterText(key('home-people-order'), '7');
        await press('home-people-save');
        await waitFor(tester, key('home-people-saved'));
        await waitFor(tester, key('home-people-row-$id'));
        expect(core.records.single['label'], 'Deniz Öztürk');
        expect(core.records.single['revision'], 1);
        expect(core.records.single['aclRevision'], 1);
        expect(core.peopleReads, reads);
        expect(core.mutations, ['POST']);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.created');
        await press('home-people-edit-$id');
        await tester.enterText(key('home-people-label'), 'Ece Öztürk');
        await tester.enterText(key('home-people-order'), '0');
        await press('home-people-save');
        await waitFor(tester, key('home-people-saved'));
        expect(core.records.single['label'], 'Ece Öztürk');
        expect(core.records.single['order'], 0);
        expect(core.records.single['revision'], 2);
        expect(core.records.single['aclRevision'], 1);
        expect(core.peopleReads, reads);
        expect(core.mutations, ['POST', 'PATCH']);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.renamed_and_ordered');

        await press('home-people-grants-$id');
        await waitFor(tester, key('home-person-grants-screen'));
        await waitFor(tester, key('home-people-user-$subject'));
        expect(find.text('fixture-person-member'), findsOneWidget);
        expect(core.usersReads, 1);
        expect(core.grantReads, 1);
        await press('home-people-user-$subject');
        await press('home-people-permission-readOnly');
        await press('home-people-grant-save');
        await waitFor(tester, key('home-people-grant-saved'));
        expect(core.records.single['revision'], 2);
        expect(core.records.single['aclRevision'], 2);
        expect(core.mutations, ['POST', 'PATCH', 'PUT']);
        expect(core.grantReads, 1);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.read_only_granted');
        await press('home-people-user-$subject');
        await press('home-people-permission-readWrite');
        await press('home-people-grant-save');
        await waitFor(tester, key('home-people-grant-saved'));
        expect(core.records.single['aclRevision'], 3);
        expect(core.mutations, ['POST', 'PATCH', 'PUT', 'PUT']);
        expect(core.grantReads, 1);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.read_write_granted');
        await press('home-people-user-$subject');
        await press('home-people-permission-none');
        await press('home-people-grant-save');
        await waitFor(tester, key('home-people-revoke-confirmation'));
        expect(find.text('Ece Öztürk'), findsOneWidget);
        expect(find.text('fixture-person-member'), findsOneWidget);
        await press('home-people-grant-cancel');
        await waitFor(tester, key('home-people-user-$subject'));
        expect(core.records.single['aclRevision'], 3);
        expect(core.mutations.length, 4);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.revoke_cancelled');
        await press('home-people-user-$subject');
        await press('home-people-permission-none');
        await press('home-people-grant-save');
        await waitFor(tester, key('home-people-revoke-confirmation'));
        await press('home-people-confirm-revoke');
        await waitFor(tester, key('home-people-grant-revoked'));
        expect(core.records.single['aclRevision'], 4);
        expect(core.records.single['revision'], 2);
        expect(core.mutations.length, 5);
        expect(core.grantReads, 1);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.revoked');

        await press('home-people-grants-back');
        await waitFor(tester, key('home-people-row-$id'));
        expect(
          core.peopleReads,
          reads + 1,
          reason: 'Child return obtains a fresh list owner and ACL revision',
        );
        await press('home-people-delete-$id');
        await waitFor(tester, key('home-people-delete-confirmation'));
        expect(find.text('Ece Öztürk'), findsOneWidget);
        await press('home-people-cancel-edit');
        await waitFor(tester, key('home-people-row-$id'));
        expect(core.records, hasLength(1));
        expect(core.mutations.length, 5);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.delete_cancelled');
        await press('home-people-delete-$id');
        await waitFor(tester, key('home-people-delete-confirmation'));
        await press('home-people-confirm-delete');
        await waitFor(tester, key('home-people-deleted'));
        await waitFor(tester, key('home-people-empty'));
        expect(core.records, isEmpty);
        expect(core.mutations, [
          'POST',
          'PATCH',
          'PUT',
          'PUT',
          'PUT',
          'DELETE',
        ]);
        expect(key('home-people-row-$id'), findsNothing);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.deleted');
        await press('home-people-refresh');
        await waitFor(tester, key('home-people-empty'));
        await waitUntil(tester, () => core.peopleReads == reads + 2);
        expect(find.text('Ece Öztürk'), findsNothing);
        expect(core.records, isEmpty);
        expect(core.mutations.length, 6);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_people_admin.fresh_empty');
      } finally {
        debugPrint('LARENOR_E2E_PHASE core_people_admin.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE core_people_admin.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
