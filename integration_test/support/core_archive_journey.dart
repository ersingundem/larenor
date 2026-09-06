import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/home_scope/presentation/core_layout_archive_screen.dart';
import 'package:larenor/features/home_scope/presentation/home_source_screen.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';

import 'app_harness.dart';
import 'single_element_ready.dart';
import 'synthetic_core_account.dart';
import 'synthetic_core_archive_files.dart';

/// Real PIN/session/scoped repository/crypto/UI; only the OS file adapter is fake.
/// Repository writes below establish test preconditions, not a room-editor claim.
void registerCoreArchiveJourney() {
  testWidgets(
    'Core room archive → encrypted export → review → explicit scoped restore',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE core_archive.begin');
      final app = await AppHarness.start(connected: true, coreSource: true);
      final core = app.server.coreAccount!;
      final files = SyntheticCoreArchiveFiles();
      const password = 'Synthetic archive passphrase 2026';
      const savedLayout = DashboardLayout(
        rooms: [
          DashboardRoom(id: 'archive-saved', name: 'Archived fixture room'),
        ],
      );
      const targetLayout = DashboardLayout(
        rooms: [
          DashboardRoom(id: 'archive-target', name: 'Replacement fixture room'),
        ],
      );
      Finder key(String name) => find.byKey(ValueKey(name));

      Future<void> visible(String name) async {
        final finder = key(name);
        if (finder.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            finder,
            250,
            scrollable: key('core-layout-archive-screen').evaluate().isEmpty
                ? find.byType(Scrollable).last
                : coreArchiveJourneyScrollable(),
            maxScrolls: 20,
          );
        }
        await waitFor(tester, finder);
        await tester.ensureVisible(finder);
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<void> press(String name) async {
        await visible(name);
        bool enabled(Element element) {
          final widget = element.widget;
          if (widget is CupertinoButton) return widget.onPressed != null;
          if (widget is CupertinoDialogAction) return widget.onPressed != null;
          return find
                  .descendant(
                    of: key(name),
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is CupertinoButton && widget.onPressed != null,
                    ),
                  )
                  .evaluate()
                  .length ==
              1;
        }

        await waitUntil(tester, () => singleElementReady(key(name), enabled));
        await tapVisible(tester, key(name));
      }

      Future<void> field(String name, String value) async {
        await visible(name);
        await tester.enterText(key(name), value);
      }

      Future<void> top() => coreArchiveJourneyTop(tester);
      Future<void> message(String text) async {
        await top();
        await waitUntil(tester, () => find.text(text).evaluate().length == 1);
        expect(key('core-layout-archive-message'), findsOneWidget);
      }

      Future<T> repository<T>(
        Future<T> Function(DashboardRepository) operation,
      ) async {
        final anchor = [
          find.byType(CoreLayoutArchiveScreen),
          find.byType(HomeSourceScreen),
          find.byType(CoreHomeStatusScreen),
        ].firstWhere((finder) => finder.evaluate().length == 1);
        final container = ProviderScope.containerOf(tester.element(anchor));
        // A live subscription retains the auto-disposed owner through each await.
        final subscription = container.listen(
          dashboardRepositoryProvider,
          (_, _) {},
        );
        try {
          return await operation(subscription.read());
        } finally {
          subscription.close();
        }
      }

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
      }

      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.reload();
        final legacyBefore = preferences.getString('dashboard_layout');
        await app.mount(tester, coreArchiveFiles: files);
        await waitFor(tester, find.byType(CoreHomeStatusScreen));
        await tapVisible(tester, find.text('Manage Core account'));
        await waitFor(tester, find.text('Unlock'));
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.byType(ServerConnectionScreen));
        await field('server-url', app.server.baseUrl);
        await field('server-username', SyntheticCoreAccount.username);
        await field('server-password', SyntheticCoreAccount.password);
        await press('server-sign-in');
        await waitFor(
          tester,
          find.text('The Core account and home are verified.'),
        );
        expect(core.logins, 1);
        expect(core.contextReads, 1);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_archive.account_verified');

        // Explicit synthetic precondition through the real source-scoped store.
        await repository((store) => store.save(savedLayout));
        final captured = await repository((store) => store.readSnapshot());
        expect(captured.revision, 1);
        expect(captured.scope!.toJson(), {
          'coreId': core.coreId,
          'homeId': core.homeId,
          'userId': core.userId,
        });
        await tapVisible(tester, find.text('Home source'));
        await waitFor(tester, find.text('Unlock'));
        expect(key('core-layout-archive-entry'), findsNothing);
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.byType(HomeSourceScreen));
        await press('core-layout-archive-entry');
        await waitFor(tester, key('core-layout-archive-screen'));
        await waitFor(tester, find.text('Archived fixture room'));
        expect(files.saves, 0);
        expect(files.picks, 0);
        debugPrint('LARENOR_E2E_PHASE core_archive.pin_opened');

        await field('core-layout-archive-password', password);
        await field('core-layout-archive-repeat', password);
        await press('core-layout-archive-export');
        await message('Encrypted room archive saved.');
        expect(files.saves, 1);
        final encrypted = files.savedCiphertext!;
        final wire = utf8.decode(encrypted);
        expect(jsonDecode(wire)['format'], 'larenor-core-layout-archive');
        for (final secret in [
          password,
          'Archived fixture room',
          'Fixture room',
          SyntheticCoreAccount.accessToken,
          SyntheticCoreAccount.refreshToken,
        ]) {
          expect(wire, isNot(contains(secret)));
        }
        for (final name in [
          'core-layout-archive-password',
          'core-layout-archive-repeat',
        ]) {
          await visible(name);
          expect(
            tester.widget<CupertinoTextField>(key(name)).controller!.text,
            isEmpty,
          );
        }
        expect(
          (await repository((store) => store.readSnapshot())).fingerprint,
          captured.fingerprint,
        );
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_archive.encrypted_export');

        // A second real scoped write creates a distinct restore target, not UI editing.
        await repository((store) => store.save(targetLayout));
        await top();
        await press('core-layout-archive-refresh');
        await waitFor(tester, find.text('Replacement fixture room'));
        final target = await repository((store) => store.readSnapshot());
        expect(target.revision, 2);
        files.queuePick(null);
        await press('core-layout-archive-pick');
        await message('File selection cancelled.');
        expect(files.picks, 1);
        expect(key('core-layout-archive-preview'), findsNothing);
        expect(
          (await repository((store) => store.readSnapshot())).fingerprint,
          target.fingerprint,
        );
        debugPrint('LARENOR_E2E_PHASE core_archive.pick_cancelled');

        files.queuePick(encrypted);
        await press('core-layout-archive-pick');
        await field(
          'core-layout-archive-open-password',
          'Wrong archive passphrase 2026',
        );
        await press('core-layout-archive-decrypt');
        await message(
          'The room archive could not be opened. Check its password and file.',
        );
        expect(files.picks, 2);
        expect(key('core-layout-archive-preview'), findsNothing);
        expect(
          (await repository((store) => store.readSnapshot())).fingerprint,
          target.fingerprint,
        );
        debugPrint('LARENOR_E2E_PHASE core_archive.wrong_password_denied');

        await field('core-layout-archive-open-password', password);
        await press('core-layout-archive-decrypt');
        await top();
        await waitFor(tester, key('core-layout-archive-preview'));
        expect(find.text('Replacement fixture room'), findsOneWidget);
        expect(find.text('Archived fixture room'), findsOneWidget);
        expect(
          (await repository((store) => store.readSnapshot())).fingerprint,
          target.fingerprint,
        );
        debugPrint('LARENOR_E2E_PHASE core_archive.preview_ready');

        await press('core-layout-archive-replace');
        await press('core-layout-archive-confirm-cancel');
        await coreArchiveJourneyConfirmationDismissed(tester);
        expect(key('core-layout-archive-confirm'), findsNothing);
        expect(key('core-layout-archive-preview'), findsOneWidget);
        expect(
          (await repository((store) => store.readSnapshot())).fingerprint,
          target.fingerprint,
        );
        debugPrint('LARENOR_E2E_PHASE core_archive.confirm_cancelled');

        await press('core-layout-archive-replace');
        await press('core-layout-archive-confirm');
        await message('Room layout replaced and verified.');
        final restored = await repository((store) => store.readSnapshot());
        expect(restored.layout, savedLayout);
        expect(restored.scope, captured.scope);
        expect(restored.revision, target.revision + 1);
        await preferences.reload();
        final record = jsonDecode(
          preferences.getString(restored.scope!.storageKey)!,
        ) as Map<String, dynamic>;
        expect(record['scope'], captured.scope!.toJson());
        expect(record['revision'], 3);
        expect(record['layout'], savedLayout.toJson());
        expect(preferences.getString('dashboard_layout'), legacyBefore);
        expect(files.saves, 1);
        expect(files.picks, 2);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_archive.scoped_restore_verified');

        await press('core-layout-archive-back');
        await waitFor(tester, find.byType(HomeSourceScreen));
        await press('core-layout-archive-entry');
        await waitFor(tester, find.text('Archived fixture room'));
        expect(find.text('Replacement fixture room'), findsNothing);
        expect((await repository((store) => store.readSnapshot())).revision, 3);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_archive.reopened_readback');
      } finally {
        debugPrint('LARENOR_E2E_PHASE core_archive.cleanup_begin');
        await app.close(tester);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_archive.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// The page owns the vertical scroll; password fields own nested horizontal ones.
Finder coreArchiveJourneyScrollable() => find
    .descendant(
      of: find.descendant(
        of: find.byKey(const ValueKey('core-layout-archive-screen')),
        matching: find.byType(ListView),
      ),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> coreArchiveJourneyConfirmationDismissed(
  WidgetTester tester,
) async {
  final confirm = find.byKey(const ValueKey('core-layout-archive-confirm'));
  final cancel = find.byKey(
    const ValueKey('core-layout-archive-confirm-cancel'),
  );
  // A successful pop can leave both actions mounted during the reverse route
  // animation. Wait for that route's removal, not a fixed frame or app idleness.
  await waitUntil(
    tester,
    () => confirm.evaluate().isEmpty && cancel.evaluate().isEmpty,
  );
  expect(confirm, findsNothing);
  expect(cancel, findsNothing);
}

Future<void> coreArchiveJourneyTop(WidgetTester tester) async {
  final scroll = coreArchiveJourneyScrollable();
  for (
    var i = 0;
    i < 20 && tester.state<ScrollableState>(scroll).position.pixels > 0;
    i++
  ) {
    await tester.drag(scroll, const Offset(0, 700));
    await tester.pump(const Duration(milliseconds: 100));
  }
  // Cupertino bounce may be below zero after the final upward swipe.
  // Wait for this page's position only, never global app quiescence.
  await waitUntil(
    tester,
    () => tester.state<ScrollableState>(scroll).position.pixels == 0,
  );
  expect(tester.state<ScrollableState>(scroll).position.pixels, 0);
}
