import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/app.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/settings/presentation/panes/display_pane.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/home_scope/presentation/home_source_screen.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/navigation/presentation/app_shell.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';

import 'home_scope_fixture.dart';

void main() {
  testWidgets(
    'actual account login waits for context without cancelling its own authority',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester);
      await tester.tap(find.text('Manage Core account'));
      await flush(tester);
      h.api.pendingContext = Completer<ServerContext>();
      await loginOnScreen(tester);
      final generation = h.account.generation;
      expect(h.account.hasPendingContext, isTrue);
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      h.api.pendingContext!.complete(h.api.identity);
      await flush(tester);
      expect(h.account.context, h.api.identity);
      expect(h.account.generation, generation);
      expect(h.account.failure, isNull);
      expect(h.api.logins, 1);
      expect(h.api.contextReads, 1);
      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      expect(h.connectionReads, 0);
    },
  );

  testWidgets(
    'source change retires callbacks before slow write and disposes root routes',
    (tester) async {
      final h = ScopeHarness(HomeSource.directLocal);
      await h.mount(tester);
      final home = h.home(tester);
      final old = h.runtime(tester);
      h.router(tester).push('/settings');
      await flush(tester);
      final interaction = AppInteractionScope.maybeRead(
        tester.element(find.byType(AppShell, skipOffstage: false)),
      );
      final epoch = interaction!.epoch;
      h.source.pendingWrite = Completer<void>();
      final switching = home.choose(HomeSource.verifiedCore);
      expect(interaction.active, isFalse);
      expect(interaction.epoch, greaterThan(epoch));
      await flush(tester);
      expect(old, isNot(same(h.runtime(tester))));
      expect(find.byType(AppShell), findsNothing);
      h.source.pendingWrite!.complete();
      await switching;
      await flush(tester);
      expect(h.source.value, HomeSource.verifiedCore);
      expect(h.router(tester).routeInformationProvider.value.uri.path, '/');
    },
  );
  testWidgets(
    'Server login and logout alone preserve direct home router and root route',
    (tester) async {
      final h = ScopeHarness(HomeSource.directLocal);
      await h.mount(tester);
      final runtime = h.runtime(tester), router = h.router(tester);
      router.push('/settings');
      await flush(tester);
      await h.signIn();
      await flush(tester);
      expect(h.runtime(tester), same(runtime));
      expect(h.router(tester), same(router));
      expect(
        find
                .byType(ServerConnectionScreen, skipOffstage: false)
                .evaluate()
                .isNotEmpty ||
            find.text('Display & Brightness').evaluate().isNotEmpty,
        isTrue,
      );
      await h.account.signOut();
      await flush(tester);
      expect(h.runtime(tester), same(runtime));
      expect(h.source.value, HomeSource.directLocal);
      expect(h.connectionReads, 1);
    },
  );

  testWidgets(
    'same verified tuple refresh keeps navigation, changed home closes old routes',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      final runtime = h.runtime(tester), router = h.router(tester);
      router.push('/settings');
      await flush(tester);
      h.now = h.now.add(const Duration(hours: 2));
      h.api.pendingContext = Completer<ServerContext>();
      final refresh = h.account.ensureSession();
      await flush(tester);
      expect(h.account.hasPendingContext, isTrue);
      expect(h.runtime(tester), same(runtime));
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      h.api.pendingContext!.complete(h.api.identity);
      await refresh;
      await flush(tester);
      expect(h.runtime(tester), same(runtime));
      expect(h.router(tester), same(router));
      expect(
        find
                .byType(ServerConnectionScreen, skipOffstage: false)
                .evaluate()
                .isNotEmpty ||
            find.text('Display & Brightness').evaluate().isNotEmpty,
        isTrue,
      );
      h.api.pendingContext = null;
      h.api.homeId = 'c' * 32;
      await h.account.ensureSession();
      await flush(tester);
      expect(h.runtime(tester), isNot(same(runtime)));
      expect(h.router(tester).routeInformationProvider.value.uri.path, '/');
      expect(find.byType(ServerConnectionScreen), findsNothing);
      expect(h.account.context!.homeId, 'c' * 32);
      expect(h.connectionReads, 0);
    },
  );

  testWidgets(
    'first password then pending context retains replacement tokens and recovery',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      h.api.requireChange = true;
      await h.mount(tester);
      h.router(tester).push('/settings');
      await flush(tester);
      await loginOnScreen(tester);
      expect(h.account.session!.user.mustChangePassword, isTrue);
      expect(h.api.contextReads, 0);
      final runtime = h.runtime(tester);
      h.api.pendingContext = Completer<ServerContext>();
      for (final field in {
        'server-current-password': 'synthetic',
        'server-new-password': 'synthetic-new-password',
        'server-confirm-password': 'synthetic-new-password',
      }.entries) {
        await tester.enterText(find.byKey(ValueKey(field.key)), field.value);
      }
      await press(tester, 'server-change-password');
      final generation = h.account.generation;
      expect(h.account.hasPendingContext, isTrue);
      expect(h.runtime(tester), same(runtime));
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      expect(h.store.value!.accessToken, isNotEmpty);
      h.api.pendingContext!.complete(h.api.identity);
      await flush(tester);
      expect(h.account.generation, generation);
      expect(h.account.failure, isNull);
      expect(h.account.context, h.api.identity);
      expect(h.api.changes, 1);
      expect(h.api.logins, 1);
    },
  );

  for (final failure in ['read', 'write']) {
    testWidgets(
      '$failure failure closes home and permits only protected source recovery',
      (tester) async {
        final h = ScopeHarness(HomeSource.directLocal);
        h.source.readFails = failure == 'read';
        await h.mount(tester, pin: '1234');
        if (failure == 'write') {
          h.source.writeFails = true;
          await h.home(tester).choose(HomeSource.verifiedCore);
          await flush(tester);
        }
        expect(find.byType(AppShell), findsNothing);
        expect(h.home(tester).failure, 'source_${failure}_failed');
        h.router(tester).push('/settings/home-source');
        await flush(tester);
        expect(find.text('Unlock'), findsOneWidget);
        expect(find.byType(HomeSourceScreen), findsNothing);
        expect(h.source.value, HomeSource.directLocal);
      },
    );
  }

  testWidgets(
    'Core logout stays Core and background closes account PIN authority',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester, pin: '1234');
      await h.signIn();
      await flush(tester);
      h.router(tester).push('/settings');
      await flush(tester);
      expect(find.text('Unlock'), findsOneWidget);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await flush(tester);
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await flush(tester);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await flush(tester);
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.byType(ServerConnectionScreen), findsNothing);
      await h.account.signOut();
      await flush(tester);
      expect(h.source.value, HomeSource.verifiedCore);
      expect(find.byType(AppShell), findsNothing);
      expect(h.connectionReads, 0);
    },
  );

  testWidgets(
    'late REST and websocket callbacks cannot enter replacement Core runtime',
    (tester) async {
      final h = ScopeHarness(HomeSource.directLocal)..localHa = true;
      await h.mount(tester);
      expect(h.rest.reads, greaterThan(0));
      h.router(tester).push('/entities/light.old');
      await flush(tester);
      await h.home(tester).choose(HomeSource.verifiedCore);
      await flush(tester);
      expect(h.rest.disposed, isTrue);
      expect(h.socket.disposed, isTrue);
      const old = HaEntity(
        entityId: 'light.old',
        state: 'on',
        attributes: {'friendly_name': 'Old home secret'},
      );
      h.rest.states.complete([old]);
      h.socket.events.add(
        const HaEntityChange(entityId: 'light.old', entity: old),
      );
      await flush(tester);
      expect(find.text('Old home secret'), findsNothing);
      expect(h.router(tester).routeInformationProvider.value.uri.path, '/');
      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual Settings writes theme and power in the visible application container',
    (tester) async {
      final h = ScopeHarness(HomeSource.directLocal);
      await h.mount(tester);
      final runtime = h.runtime(tester);
      h.router(tester).push('/settings');
      await flush(tester);
      await tester.tap(find.text('Display & Brightness'));
      await flush(tester);
      expect(find.byType(DisplayPane), findsOneWidget);
      await tester.ensureVisible(find.text('Appearance'));
      await tester.tap(find.text('Appearance'));
      await flush(tester);
      await tester.tap(find.text('Dark'));
      await flush(tester);
      expect(runtime.read(appearanceProvider).value, AppAppearance.dark);
      expect(
        tester
            .widget<CupertinoApp>(find.byType(CupertinoApp))
            .theme!
            .brightness,
        Brightness.dark,
      );
      final toggle = find
          .descendant(
            of: find.byType(DisplayPane),
            matching: find.byType(CupertinoSwitch),
          )
          .first;
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await flush(tester);
      expect(runtime.read(keepScreenOnProvider).value, isTrue);
      expect(h.power.awake, isTrue);
      expect(h.runtime(tester), same(runtime));
    },
  );

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language $width 2x Core status and source choice stay usable',
        (tester) async {
          final h = ScopeHarness(HomeSource.verifiedCore);
          await h.mount(tester, locale: language, width: width, scale: 2);
          expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
          expect(find.byType(AppShell), findsNothing);
          h.router(tester).push('/settings/home-source');
          await flush(tester);
          expect(find.byType(HomeSourceScreen), findsOneWidget);
          expect(
            find.text(language == 'tr' ? 'Ev kaynağı' : 'Home source'),
            findsOneWidget,
          );
          for (final source in HomeSource.values) {
            final row = find.byKey(ValueKey('home-source-${source.name}'));
            await tester.ensureVisible(row);
            await flush(tester);
            expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
            expect(tester.widget<SettingsActionTile>(row).onTap, isNotNull);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Core context 404 keeps explicit source and retries only the context read',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      h.api.contextFailure = 'context_endpoint_unavailable';
      await h.mount(tester);
      h.router(tester).push('/settings');
      await flush(tester);
      await loginOnScreen(tester);
      final runtime = h.runtime(tester);
      expect(h.account.hasPendingContext, isTrue);
      expect(h.account.failure, 'context_endpoint_unavailable');
      expect(h.source.value, HomeSource.verifiedCore);
      expect(h.connectionReads, 0);
      h.api.contextFailure = null;
      await tester.ensureVisible(find.text('Retry context check'));
      await tester.tap(find.text('Retry context check'));
      await flush(tester);
      expect(h.api.logins, 1);
      expect(h.api.refreshes, 0);
      expect(h.api.contextReads, 2);
      expect(h.account.context, h.api.identity);
      expect(h.runtime(tester), isNot(same(runtime)));
      expect(find.byType(AppShell), findsNothing);
    },
  );

  testWidgets(
    'idle invalidates source choice callback and waking cannot replay it',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore)..ambientPhotos = true;
      await h.mount(tester);
      h.router(tester).push('/settings/home-source');
      await flush(tester);
      final row = find.byKey(const ValueKey('home-source-directLocal'));
      final callback = tester.widget<SettingsActionTile>(row).onTap!;
      await h.runtime(tester).read(idleModeProvider.notifier).setEnabled(true);
      await h
          .runtime(tester)
          .read(idleModeProvider.notifier)
          .setTimeoutMinutes(1);
      await flush(tester);
      await tester.pump(const Duration(minutes: 1));
      await flush(tester);
      expect(h.connectionReads, 0);
      expect(h.ambientReads, 0);
      callback();
      expect(h.source.writes, 0);
      await tester.tapAt(const Offset(40, 40));
      await flush(tester);
      callback();
      expect(h.source.writes, 0);
      expect(h.source.value, HomeSource.verifiedCore);
    },
  );

  testWidgets(
    'source selection recovers a failed read, stale same-frame activation cannot duplicate write',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      h.source.readFails = true;
      await h.mount(tester);
      h.router(tester).push('/settings/home-source');
      await flush(tester);
      final row = find.byKey(const ValueKey('home-source-directLocal'));
      final callback = tester.widget<SettingsActionTile>(row).onTap!;
      h.source.pendingWrite = Completer<void>();
      callback();
      callback();
      expect(h.source.writes, 1);
      await flush(tester);
      expect(find.byType(AppShell), findsNothing);
      h.source.pendingWrite!.complete();
      await flush(tester);
      callback();
      expect(h.source.writes, 1);
      expect(h.home(tester).source, HomeSource.directLocal);
      expect(find.byType(AppShell), findsOneWidget);
    },
  );

  testWidgets(
    'configuration restore remount rereads saved Core choice and preserves account ownership',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      final runtime = h.runtime(tester);
      final generation = h.account.generation;
      final restore = ConfigurationScope.restore(
        tester.element(find.byType(LarenorApp)),
        operation: () async {},
        progressLabel: 'Restoring',
        failureLabel: 'Failed',
        continueLabel: 'Continue',
      );
      await flush(tester);
      await restore;
      await flush(tester);
      expect(h.source.reads, 2);
      expect(h.source.value, HomeSource.verifiedCore);
      expect(h.runtime(tester), isNot(same(runtime)));
      expect(h.account.generation, generation);
      expect(h.account.context, h.api.identity);
      expect(h.connectionReads, 0);
    },
  );

  testWidgets(
    'each verified Core identity component retires previous root navigation',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      var runtime = h.runtime(tester);
      h.now = h.now.add(const Duration(hours: 2));
      h.api.coreId = 'd' * 32;
      await h.account.ensureSession();
      await flush(tester);
      expect(h.runtime(tester), isNot(same(runtime)));
      runtime = h.runtime(tester);
      await h.account.signOut();
      h.api.userId = 'two';
      await h.signIn();
      await flush(tester);
      expect(h.runtime(tester), isNot(same(runtime)));
      expect(h.account.session!.user.id, 'two');
      expect(h.connectionReads, 0);
    },
  );

  testWidgets(
    'Core recovery buttons use protected routes and nested root back returns to status',
    (tester) async {
      final h = ScopeHarness(HomeSource.verifiedCore);
      await h.mount(tester);
      await tester.tap(find.text('Home source'));
      await flush(tester);
      expect(find.byType(HomeSourceScreen), findsOneWidget);
      await tester.tap(find.byType(CupertinoNavigationBarBackButton).first);
      await flush(tester);
      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      await tester.tap(find.text('Manage Core account'));
      await flush(tester);
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      await tester.tap(find.byType(CupertinoNavigationBarBackButton).first);
      await flush(tester);
      h.router(tester).go('/entities/light.old');
      await flush(tester);
      expect(find.byType(CoreHomeStatusScreen), findsOneWidget);
      expect(h.connectionReads, 0);
    },
  );
  testWidgets(
    'direct home idle mode retains its explicit local photo library',
    (tester) async {
      final h = ScopeHarness(HomeSource.directLocal)..ambientPhotos = true;
      await h.mount(tester);
      await h.runtime(tester).read(idleModeProvider.notifier).setEnabled(true);
      await h
          .runtime(tester)
          .read(idleModeProvider.notifier)
          .setTimeoutMinutes(1);
      await flush(tester);
      await tester.pump(const Duration(minutes: 1));
      await flush(tester);
      expect(h.ambientReads, 1);
      expect(h.connectionReads, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'first install source page closes when a settings PIN is created',
    (tester) async {
      final h = ScopeHarness(HomeSource.directLocal);
      await h.mount(tester);
      await press(tester, 'connect-larenor-server');
      expect(
        tester
            .widget<ServerConnectionScreen>(find.byType(ServerConnectionScreen))
            .freshInstall,
        isTrue,
      );
      await tester.tap(find.text('Home source'));
      await flush(tester);
      expect(find.byType(HomeSourceScreen), findsOneWidget);
      final old = tester
          .widget<SettingsActionTile>(
            find.byKey(const ValueKey('home-source-verifiedCore')),
          )
          .onTap!;
      await h.runtime(tester).read(pinLockProvider.notifier).setPin('1234');
      await flush(tester);
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.byType(HomeSourceScreen), findsNothing);
      old();
      await flush(tester);
      expect(h.source.value, HomeSource.directLocal);
      expect(h.source.writes, 0);
    },
  );
  testWidgets('source picker visibly marks exactly the persisted source', (tester) async {
    final h = ScopeHarness(HomeSource.verifiedCore);
    await h.mount(tester);
    h.router(tester).push('/settings/home-source');
    await flush(tester);
    expect(find.byIcon(CupertinoIcons.check_mark), findsOneWidget);
    final selected = tester.widget<SettingsActionTile>(find.byKey(const ValueKey('home-source-verifiedCore')));
    final other = tester.widget<SettingsActionTile>(find.byKey(const ValueKey('home-source-directLocal')));
    expect(selected.selected, isTrue);
    expect(other.selected, isFalse);
    expect(selected.leading, isA<Icon>());
    expect(other.leading, isA<SizedBox>());
  });

}
