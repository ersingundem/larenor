import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:larenor/shared/widgets/app_navigation_bar.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_scope/presentation/core_home_status_screen.dart';
import 'package:larenor/features/home_scope/presentation/home_source_screen.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/backup/data/backup_codec.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/dashboard/presentation/home_dashboard_screen.dart';
import 'package:larenor/features/navigation/presentation/destination_screens.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/features/settings/data/screen_program_store.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';

import 'support/app_harness.dart';
import 'support/synthetic_ha_server.dart';
import 'support/synthetic_core_account.dart';
import 'support/synthetic_core_resources.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'cold start → rejected login → dashboard → routines → PIN protected settings',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE cold_start.begin');
      final app = await AppHarness.start();
      try {
        await app.mount(tester);
        debugPrint('LARENOR_E2E_PHASE cold_start.mounted');
        await waitFor(tester, find.byType(ConnectScreen));
        debugPrint('LARENOR_E2E_PHASE cold_start.connect_screen_ready');
        final inputs = find.byType(CupertinoTextField);
        await tester.enterText(inputs.at(0), app.server.baseUrl);
        await tester.enterText(inputs.at(1), 'synthetic-rejected-token');
        await tapVisible(
          tester,
          find.widgetWithText(CupertinoButton, 'Connect'),
        );
        await waitFor(tester, find.text('Invalid or expired access token.'));
        debugPrint('LARENOR_E2E_PHASE cold_start.login_rejected');
        expect(app.server.rejectedLogins, 1);
        expect(find.byType(HomeDashboardScreen), findsNothing);
        await tester.enterText(inputs.at(1), SyntheticHaServer.token);
        await tapVisible(
          tester,
          find.widgetWithText(CupertinoButton, 'Connect'),
        );
        await waitFor(tester, find.text('Fixture temperature'));
        debugPrint('LARENOR_E2E_PHASE cold_start.dashboard_ready');
        expect(app.server.reads, contains('/api/states'));
        expect(app.server.subscriptions, greaterThan(0));
        await tapVisible(
          tester,
          find.descendant(
            of: find.byType(AppNavigationBar),
            matching: find.text('Routines'),
          ),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('routine-scene.fixture_evening')),
        );
        await waitFor(tester, find.byType(EntityDestinationScreen));
        debugPrint('LARENOR_E2E_PHASE cold_start.routine_detail_ready');
        expect(
          app.server.rejectedWrites,
          0,
          reason: 'Opening a routine must not execute it',
        );
        await tester.pageBack();
        await tester.pump(const Duration(milliseconds: 400));
        await tapVisible(
          tester,
          find.descendant(
            of: find.byType(AppNavigationBar),
            matching: find.text('System'),
          ),
        );
        await waitFor(tester, find.text('Home Assistant'));
        debugPrint('LARENOR_E2E_PHASE cold_start.system_ready');
        await tapVisible(
          tester,
          find.descendant(
            of: find.byType(AppNavigationBar),
            matching: find.text('Media'),
          ),
        );
        await tapVisible(
          tester,
          find.descendant(
            of: find.byType(AppNavigationBar),
            matching: find.text('Home'),
          ),
        );
        await waitFor(tester, find.text('Fixture temperature'));
        debugPrint('LARENOR_E2E_PHASE cold_start.dashboard_returned');
        await tapVisible(tester, find.byKey(const ValueKey('global-settings')));
        await waitFor(tester, find.text('Unlock'));
        debugPrint('LARENOR_E2E_PHASE cold_start.pin_prompt_ready');
        expect(find.byType(BackupScreen), findsNothing);
        await tester.enterText(find.byType(CupertinoTextField), '0000');
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.text('Incorrect PIN'));
        debugPrint('LARENOR_E2E_PHASE cold_start.pin_rejected');
        expect(find.text('Backup & Restore'), findsNothing);
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.byType(SettingsSplitScreen));
        debugPrint('LARENOR_E2E_PHASE cold_start.settings_unlocked');
        await tester.pageBack();
        await tester.pump(const Duration(milliseconds: 400));
        await tapVisible(tester, find.byKey(const ValueKey('global-settings')));
        await waitFor(tester, find.text('Unlock'));
        debugPrint('LARENOR_E2E_PHASE cold_start.settings_relocked');
        expect(
          find.text('Backup & Restore'),
          findsNothing,
          reason: 'Leaving Settings drops unlock authority',
        );
      } finally {
        debugPrint('LARENOR_E2E_PHASE cold_start.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE cold_start.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'encrypted vault → cancelled picker → wrong password → preview → local restore and fresh PIN',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE vault_restore.begin');
      final app = await AppHarness.start(connected: true);
      try {
        await app.mount(tester);
        debugPrint('LARENOR_E2E_PHASE vault_restore.mounted');
        await waitFor(tester, find.text('Fixture temperature'));
        await openSettings(tester);
        debugPrint('LARENOR_E2E_PHASE vault_restore.settings_unlocked');
        expect(app.wsClientsCreated, greaterThan(0));
        await tapVisible(tester, find.text('Backup & Restore'));
        await waitFor(tester, find.byType(BackupScreen));
        expect(
          tester
              .widget<CupertinoSwitch>(
                find.byKey(const ValueKey('backup-connections')),
              )
              .value,
          isFalse,
        );
        await tester.enterText(
          find.byKey(const ValueKey('backup-passphrase')),
          AppHarness.passphrase,
        );
        await tester.enterText(
          find.byKey(const ValueKey('backup-confirm-passphrase')),
          AppHarness.passphrase,
        );
        await tapVisible(tester, find.byKey(const ValueKey('backup-export')));
        await waitFor(
          tester,
          find.text(
            'Encrypted backup saved. Keep the passphrase somewhere safe.',
          ),
          timeout: const Duration(seconds: 30),
        );
        debugPrint('LARENOR_E2E_PHASE vault_restore.export_saved');
        expect(app.files.saves, 1);
        expect(app.files.filename, endsWith('.larenor-vault'));
        final raw = utf8.decode(app.files.ciphertext!, allowMalformed: true);
        expect(raw, isNot(contains('Fixture room')));
        expect(raw, isNot(contains(SyntheticHaServer.token)));
        final snapshot = await const BackupCodec().decrypt(
          app.files.ciphertext!,
          AppHarness.passphrase,
        );
        expect(snapshot.hasConnections, isFalse);
        // Model a later local edit; import must restore the captured layout only
        // after preview and explicit confirmation, through ConfigurationScope.
        await DashboardRepository().save(
          const DashboardLayout(
            rooms: [DashboardRoom(id: 'later-room', name: 'Later local room')],
          ),
        );
        await tapVisible(tester, find.text('Restore from backup'));
        app.files.cancelNextPick = true;
        await tapVisible(tester, find.byKey(const ValueKey('backup-pick')));
        await waitFor(
          tester,
          find.text('Cancelled. No settings were changed.'),
        );
        debugPrint('LARENOR_E2E_PHASE vault_restore.picker_cancelled');
        expect(
          (await DashboardRepository().load()).rooms.single.name,
          'Later local room',
        );
        await tapVisible(tester, find.byKey(const ValueKey('backup-pick')));
        await tester.enterText(
          find.byKey(const ValueKey('backup-restore-passphrase')),
          'Incorrect passphrase for fixture',
        );
        await tapVisible(tester, find.byKey(const ValueKey('backup-decrypt')));
        await waitFor(
          tester,
          find.text(
            'Could not unlock this backup. Check the passphrase and that the file is complete.',
          ),
          timeout: const Duration(seconds: 30),
        );
        debugPrint('LARENOR_E2E_PHASE vault_restore.passphrase_rejected');
        expect(find.byKey(const ValueKey('backup-apply')), findsNothing);
        expect(
          (await DashboardRepository().load()).rooms.single.name,
          'Later local room',
        );
        await tester.enterText(
          find.byKey(const ValueKey('backup-restore-passphrase')),
          AppHarness.passphrase,
        );
        await tapVisible(tester, find.byKey(const ValueKey('backup-decrypt')));
        await waitUntil(
          tester,
          () => find
              .byKey(const ValueKey('backup-restore-passphrase'))
              .evaluate()
              .isEmpty,
        );
        await tester.drag(find.byType(ListView).last, const Offset(0, 900));
        await tester.pump(const Duration(milliseconds: 400));
        await waitFor(
          tester,
          find.text('Restore preview'),
          timeout: const Duration(seconds: 30),
        );
        debugPrint('LARENOR_E2E_PHASE vault_restore.preview_ready');
        await tapVisible(tester, find.text('Replace selected'));
        await tapVisible(tester, find.byKey(const ValueKey('backup-apply')));
        await waitFor(tester, find.text('Restore this device?'));
        expect(
          (await DashboardRepository().load()).rooms.single.name,
          'Later local room',
        );
        final previousAuthentications = app.server.authentications;
        final previousSubscriptions = app.server.subscriptions;
        final previousClosed = app.server.closedSockets;
        await tapVisible(
          tester,
          find.widgetWithText(
            CupertinoDialogAction,
            'Restore selected content',
          ),
        );
        await waitFor(
          tester,
          find.text('Fixture temperature'),
          timeout: const Duration(seconds: 30),
        );
        debugPrint('LARENOR_E2E_PHASE vault_restore.dashboard_restored');
        expect(
          (await DashboardRepository().load()).rooms.single.name,
          'Fixture room',
        );
        await waitUntil(
          tester,
          () =>
              app.server.authentications > previousAuthentications &&
              app.server.subscriptions > previousSubscriptions &&
              app.server.closedSockets > previousClosed,
          describe: () =>
              'Before auth/sub/closed=$previousAuthentications/$previousSubscriptions/$previousClosed; after=${app.server.authentications}/${app.server.subscriptions}/${app.server.closedSockets}; blocked=${app.network.blocked}; clients=${app.wsClientsCreated}',
        );
        expect(
          app.server.authentications,
          greaterThan(previousAuthentications),
        );
        expect(app.server.subscriptions, greaterThan(previousSubscriptions));
        expect(
          app.server.closedSockets,
          greaterThan(previousClosed),
          reason: 'Restore must close the former HA session',
        );
        expect(find.byType(BackupScreen), findsNothing);
        await tapVisible(tester, find.byKey(const ValueKey('global-settings')));
        await waitFor(tester, find.text('Unlock'));
        debugPrint('LARENOR_E2E_PHASE vault_restore.settings_relocked');
        expect(find.text('Backup & Restore'), findsNothing);
      } finally {
        debugPrint('LARENOR_E2E_PHASE vault_restore.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE vault_restore.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'fixture light command → accepted receipt → fresh WS state confirmation',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE light_action.begin');
      final app = await AppHarness.start(connected: true);
      app.server.allowLightActions = true;
      try {
        await app.mount(tester);
        debugPrint('LARENOR_E2E_PHASE light_action.mounted');
        await waitFor(tester, find.text('Fixture temperature'));
        debugPrint('LARENOR_E2E_PHASE light_action.dashboard_ready');
        await tapVisible(tester, find.byKey(const ValueKey('global-search')));
        await waitFor(tester, find.byType(CupertinoSearchTextField));
        await tester.enterText(
          find.byType(CupertinoSearchTextField),
          'Fixture lamp',
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('entity:light.fixture_lamp')),
        );
        await waitFor(tester, find.byType(EntityDestinationScreen));
        debugPrint('LARENOR_E2E_PHASE light_action.detail_ready');
        await tapVisible(
          tester,
          find.descendant(
            of: find.byType(EntityDestinationScreen),
            matching: find.byType(CupertinoSwitch),
          ),
        );
        await waitFor(
          tester,
          find.text('Request accepted · waiting for state'),
        );
        debugPrint('LARENOR_E2E_PHASE light_action.request_accepted');
        expect(app.server.acceptedActions, ['light.turn_on']);
        expect(app.server.entities[1]['state'], 'off');
        expect(
          find.text('Requested state reported by Home Assistant'),
          findsNothing,
        );
        app.server.observePendingLight();
        await waitFor(
          tester,
          find.text('Requested state reported by Home Assistant'),
        );
        debugPrint('LARENOR_E2E_PHASE light_action.state_observed');
        expect(app.server.entities[1]['state'], 'on');
        expect(app.server.acceptedActions, [
          'light.turn_on',
        ], reason: 'No retry or duplicate write');
      } finally {
        debugPrint('LARENOR_E2E_PHASE light_action.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE light_action.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'PIN settings → weekly schedule → explicit save → new app scope preserves schedule',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE screen_schedule.begin');
      final app = await AppHarness.start(connected: true);
      try {
        await app.mount(tester);
        debugPrint('LARENOR_E2E_PHASE screen_schedule.mounted');
        await waitFor(tester, find.text('Fixture temperature'));
        await openSettings(tester);
        debugPrint('LARENOR_E2E_PHASE screen_schedule.settings_unlocked');
        await tapVisible(tester, find.text('Display & Brightness'));
        await tapVisible(tester, find.text('Screen schedule'));
        final initial = await PreferenceScreenProgramStore().read();
        await tapVisible(
          tester,
          find.byKey(const ValueKey('screen-program-add')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('screen-rule-name')),
          'Fixture weekdays',
        );
        for (final day in [6, 7]) {
          await tapVisible(
            tester,
            find.byKey(ValueKey('screen-rule-day-$day')),
          );
        }
        await tapVisible(
          tester,
          find.byKey(const ValueKey('screen-rule-all-day')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('screen-rule-mode-systemTimeout')),
        );
        await tapVisible(tester, find.byKey(const ValueKey('screen-rule-dim')));
        expect(await PreferenceScreenProgramStore().read(), initial);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('screen-rule-save')),
        );
        await waitUntil(
          tester,
          () =>
              find.byKey(const ValueKey('screen-rule-name')).evaluate().isEmpty,
        );
        await waitFor(tester, find.text('Fixture weekdays'));
        debugPrint('LARENOR_E2E_PHASE screen_schedule.rule_saved');
        await tapVisible(
          tester,
          find.byKey(const ValueKey('screen-program-enabled')),
        );
        final saved = await PreferenceScreenProgramStore().read();
        debugPrint('LARENOR_E2E_PHASE screen_schedule.persisted_program_read');
        final program = ScreenProgram.decode(saved!);
        expect(program.enabled, isTrue);
        final rule = program.rules.single;
        expect(rule.days, {1, 2, 3, 4, 5});
        expect(rule.startMinutes, 0);
        expect(rule.endMinutes, 1440);
        expect(rule.awake, ScreenAwakeMode.systemTimeout);
        expect(rule.dim, isFalse);
        // New widget/provider tree, same persistence adapter; not a process restart.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await app.mount(tester);
        debugPrint('LARENOR_E2E_PHASE screen_schedule.remounted');
        await waitFor(tester, find.text('Fixture temperature'));
        await openSettings(tester);
        await tapVisible(tester, find.text('Display & Brightness'));
        await tapVisible(tester, find.text('Screen schedule'));
        await waitFor(tester, find.text('Fixture weekdays'));
        debugPrint('LARENOR_E2E_PHASE screen_schedule.saved_rule_visible');
        expect(await PreferenceScreenProgramStore().read(), saved);
        expect(
          tester
              .widget<CupertinoSwitch>(
                find.byKey(const ValueKey('screen-program-enabled')),
              )
              .value,
          isTrue,
        );
      } finally {
        debugPrint('LARENOR_E2E_PHASE screen_schedule.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE screen_schedule.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'direct HA → PIN protected Core choice → retired HA → explicit direct reconnection',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE home_source.begin');
      final app = await AppHarness.start(connected: true);
      try {
        await app.mount(tester);
        await waitFor(tester, find.text('Fixture temperature'));
        await waitUntil(tester, () => app.server.subscriptions > 0);
        debugPrint('LARENOR_E2E_PHASE home_source.direct_ready');
        final oldClients = app.wsClientsCreated;
        final oldSubscriptions = app.server.subscriptions;
        await openSettings(tester);
        await tapVisible(tester, find.text('Larenor Server'));
        await waitFor(tester, find.byType(ServerConnectionScreen));
        await tapVisible(tester, find.text('Home source'));
        await waitFor(tester, find.byType(HomeSourceScreen));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('home-source-verifiedCore')),
        );
        await waitFor(tester, find.byType(CoreHomeStatusScreen));
        await waitUntil(tester, () => app.server.closedSockets >= oldClients);
        debugPrint('LARENOR_E2E_PHASE home_source.core_retired_local');
        expect(find.byType(HomeDashboardScreen), findsNothing);
        expect(find.text('Fixture temperature'), findsNothing);
        expect(app.wsClientsCreated, oldClients);
        expect(
          (await SharedPreferences.getInstance()).getString(
            SharedPreferencesHomeSourceStore.key,
          ),
          HomeSource.verifiedCore.name,
        );
        final reads = app.server.reads.length;
        await tester.pump(const Duration(milliseconds: 500));
        expect(app.server.reads.length, reads);
        await tapVisible(tester, find.text('Home source'));
        await waitFor(tester, find.text('Unlock'));
        expect(find.byType(HomeSourceScreen), findsNothing);
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.byType(HomeSourceScreen));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('home-source-directLocal')),
        );
        await waitFor(tester, find.text('Fixture temperature'));
        await waitUntil(
          tester,
          () => app.server.subscriptions > oldSubscriptions,
        );
        debugPrint('LARENOR_E2E_PHASE home_source.direct_reconnected');
        expect(app.wsClientsCreated, greaterThan(oldClients));
        expect(
          (await SharedPreferences.getInstance()).getString(
            SharedPreferencesHomeSourceStore.key,
          ),
          HomeSource.directLocal.name,
        );
        expect(find.byType(CoreHomeStatusScreen), findsNothing);
      } finally {
        debugPrint('LARENOR_E2E_PHASE home_source.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE home_source.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'Core login → PIN room copy → app remount → another Core stays empty',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE scoped_layout.begin');
      final app = await AppHarness.start(connected: true, coreSource: true);
      final core = app.server.coreAccount!;

      Future<void> unlock() async {
        await waitFor(tester, find.text('Unlock'));
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
      }

      Future<void> openSource() async {
        await tapVisible(tester, find.text('Home source'));
        await unlock();
        await waitFor(tester, find.byType(HomeSourceScreen));
      }

      Future<DashboardLayout> currentLayout() async {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HomeSourceScreen)),
        );
        // Match a mounted consumer's lifetime while the auto-disposed
        // repository performs its guarded asynchronous read.
        final subscription = container.listen(
          dashboardRepositoryProvider,
          (_, _) {},
        );
        try {
          return await subscription.read().load();
        } finally {
          subscription.close();
        }
      }

      Future<void> remount() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
        await app.mount(tester);
        await waitFor(
          tester,
          find.text('The Core account and home are verified.'),
        );
      }

      try {
        final preferences = await SharedPreferences.getInstance();
        final legacyBefore = preferences.getString('dashboard_layout');
        await app.mount(tester);
        await waitFor(tester, find.byType(CoreHomeStatusScreen));
        expect(find.text('Fixture room'), findsNothing);
        expect(app.server.reads, isEmpty);
        expect(app.wsClientsCreated, 0);
        expect(app.server.requests, 0);

        await tapVisible(tester, find.text('Manage Core account'));
        await waitFor(tester, find.text('Unlock'));
        expect(find.byType(ServerConnectionScreen), findsNothing);
        await tester.enterText(find.byType(CupertinoTextField), '0000');
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.text('Incorrect PIN'));
        expect(core.logins, 0);
        await unlock();
        await waitFor(tester, find.byType(ServerConnectionScreen));
        await tester.enterText(
          find.byKey(const ValueKey('server-url')),
          app.server.baseUrl,
        );
        await tester.enterText(
          find.byKey(const ValueKey('server-username')),
          SyntheticCoreAccount.username,
        );
        await tester.enterText(
          find.byKey(const ValueKey('server-password')),
          SyntheticCoreAccount.password,
        );
        await tapVisible(tester, find.byKey(const ValueKey('server-sign-in')));
        await waitFor(
          tester,
          find.text('The Core account and home are verified.'),
        );
        expect(core.logins, 1);
        expect(core.contextReads, 1);
        debugPrint('LARENOR_E2E_PHASE scoped_layout.account_verified');

        await openSource();
        expect((await currentLayout()).rooms, isEmpty);
        expect(find.text('Fixture room'), findsNothing);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('home-layout-preview-entry')),
        );
        await waitFor(
          tester,
          find.byKey(const ValueKey('home-layout-preview-screen')),
        );
        await waitFor(tester, find.text('Fixture room'));
        debugPrint('LARENOR_E2E_PHASE scoped_layout.preview_ready');
        // Approval is a separate interaction; entering preview creates no record.
        expect(
          preferences.getKeys().where(
            (key) => key.startsWith('dashboard_layout_core_v1_'),
          ),
          isEmpty,
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('home-layout-room-0')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('home-layout-copy-selected')),
        );
        await waitFor(
          tester,
          find.byKey(const ValueKey('home-layout-confirm-copy')),
        );
        expect(
          preferences.getKeys().where(
            (key) => key.startsWith('dashboard_layout_core_v1_'),
          ),
          isEmpty,
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('home-layout-confirm-copy')),
        );
        await waitFor(
          tester,
          find.byKey(const ValueKey('home-layout-copy-complete')),
        );
        // Preferences/secure storage are synthetic in this harness. Reload and
        // app remount prove the plugin persistence boundary and fresh provider
        // ownership, not an Android process restart or physical-device disk.
        await preferences.reload();
        final scopedKey = preferences.getKeys().singleWhere(
          (key) => key.startsWith('dashboard_layout_core_v1_'),
        );
        final stored = jsonDecode(
          preferences.getString(scopedKey)!,
        ) as Map<String, dynamic>;
        expect(stored['scope'], {
          'coreId': core.coreId,
          'homeId': core.homeId,
          'userId': core.userId,
        });
        expect(
          jsonEncode(stored),
          isNot(contains('sensor.fixture_temperature')),
        );
        expect(jsonEncode(stored), isNot(contains('light.fixture_lamp')));
        expect(preferences.getString('dashboard_layout'), legacyBefore);
        debugPrint('LARENOR_E2E_PHASE scoped_layout.copy_saved');

        final originalCore = core.coreId, originalHome = core.homeId;
        await remount();
        await openSource();
        final restored = await currentLayout();
        expect(restored.rooms.single.name, 'Fixture room');
        expect(restored.rooms.single.entityIds, isEmpty);
        expect(restored.rooms.single.areaBinding, isNull);
        expect(restored.favoriteEntityIds, isEmpty);
        debugPrint('LARENOR_E2E_PHASE scoped_layout.remount_restored');

        core.coreId = 'c' * 32;
        core.homeId = 'd' * 32;
        await remount();
        await openSource();
        expect((await currentLayout()).rooms, isEmpty);
        expect(
          preferences.getKeys().where(
            (key) => key.startsWith('dashboard_layout_core_v1_'),
          ),
          [scopedKey],
        );
        debugPrint('LARENOR_E2E_PHASE scoped_layout.other_core_empty');

        core.coreId = originalCore;
        core.homeId = originalHome;
        await remount();
        await openSource();
        expect((await currentLayout()).rooms.single.name, 'Fixture room');
        expect(core.meReads, 3);
        expect(core.contextReads, 4);
        expect(app.server.reads, isEmpty);
        expect(app.server.requests, 0);
        expect(app.server.rejectedLogins, 0);
        expect(app.wsClientsCreated, 0);
        expect(app.server.subscriptions, 0);
        expect(preferences.getString('dashboard_layout'), legacyBefore);
        debugPrint('LARENOR_E2E_PHASE scoped_layout.original_core_restored');
      } finally {
        debugPrint('LARENOR_E2E_PHASE scoped_layout.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE scoped_layout.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'Core member resources → revoked permission → explicit refresh → another Core',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE core_resources.begin');
      final app = await AppHarness.start(
        connected: true,
        coreSource: true,
        coreResources: true,
      );
      final core = app.server.coreAccount!;
      final resources = core.resources!;
      final room = find.byKey(ValueKey('home-resource-${'1' * 32}'));
      final lamp = find.byKey(ValueKey('home-resource-${'3' * 32}'));
      final refresh = find.byKey(const ValueKey('home-resources-refresh'));
      final empty = find.byKey(const ValueKey('home-resources-empty'));

      Future<void> remount(String expectedLabel) async {
        final meReads = core.meReads, contextReads = core.contextReads;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
        await app.mount(tester);
        await waitFor(tester, find.text(expectedLabel));
        expect(core.meReads, greaterThan(meReads));
        expect(core.contextReads, greaterThan(contextReads));
      }

      try {
        final prefs = await SharedPreferences.getInstance();
        final legacy = prefs.getString('dashboard_layout');
        await app.mount(tester);
        await waitFor(tester, find.byType(CoreHomeStatusScreen));
        expect(room, findsNothing);
        expect(lamp, findsNothing);
        expect(resources.reads, 0);
        await tapVisible(tester, find.text('Manage Core account'));
        await waitFor(tester, find.text('Unlock'));
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.byType(ServerConnectionScreen));
        await tester.enterText(
          find.byKey(const ValueKey('server-url')),
          app.server.baseUrl,
        );
        await tester.enterText(
          find.byKey(const ValueKey('server-username')),
          SyntheticCoreAccount.username,
        );
        await tester.enterText(
          find.byKey(const ValueKey('server-password')),
          SyntheticCoreAccount.password,
        );
        await tapVisible(tester, find.byKey(const ValueKey('server-sign-in')));
        await waitFor(tester, room);
        await waitFor(tester, lamp);
        expect(core.user['role'], 'member');
        expect(find.byKey(ValueKey('home-resource-${'2' * 32}')), findsNothing);
        expect(find.byKey(ValueKey('home-resource-${'4' * 32}')), findsNothing);
        expect(resources.reads, 1);
        debugPrint('LARENOR_E2E_PHASE core_resources.member_visible_only');

        // ACL changes are observed on a new authorized request, not a pretend
        // push channel. A refresh must replace the prior permission snapshot.
        resources.view = SyntheticCoreResourceView.revoked;
        await tapVisible(tester, refresh);
        await waitFor(tester, lamp);
        expect(room, findsNothing);
        expect(resources.reads, 2);
        debugPrint('LARENOR_E2E_PHASE core_resources.revoked_after_refresh');

        resources.view = SyntheticCoreResourceView.empty;
        await tapVisible(tester, refresh);
        await waitFor(tester, empty);
        expect(room, findsNothing);
        expect(lamp, findsNothing);
        expect(find.text('Fixture room'), findsNothing);
        expect(resources.reads, 3);
        debugPrint('LARENOR_E2E_PHASE core_resources.empty_without_legacy');

        core.coreId = 'c' * 32;
        core.homeId = 'd' * 32;
        await remount('İkinci ev · Salon');
        expect(find.text('Salon'), findsNothing);
        expect(find.text('Okuma lambası'), findsNothing);
        expect(find.text('İkinci ev · Okuma lambası'), findsOneWidget);
        expect(resources.requestedScopes.last, ('c' * 32, 'd' * 32));
        expect(resources.reads, 4);
        debugPrint('LARENOR_E2E_PHASE core_resources.other_core_verified');

        core.coreId = 'a' * 32;
        core.homeId = 'b' * 32;
        resources.view = SyntheticCoreResourceView.member;
        await remount('Salon');
        expect(find.text('İkinci ev · Salon'), findsNothing);
        expect(find.text('İkinci ev · Okuma lambası'), findsNothing);
        expect(find.text('Okuma lambası'), findsOneWidget);
        expect(resources.requestedScopes.last, ('a' * 32, 'b' * 32));
        expect(resources.reads, 5);
        await prefs.reload();
        expect(prefs.getString('dashboard_layout'), legacy);
        expect(app.server.requests, 0);
        expect(app.server.rejectedLogins, 0);
        expect(app.server.acceptedActions, isEmpty);
        expect(app.wsClientsCreated, 0);
        expect(app.server.subscriptions, 0);
        expect(core.rejectedRequests, 0);
        debugPrint('LARENOR_E2E_PHASE core_resources.original_scope_restored');
      } finally {
        debugPrint('LARENOR_E2E_PHASE core_resources.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE core_resources.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'Core admin → PIN → create → rename and order → confirm delete → fresh read',
    (tester) async {
      debugPrint('LARENOR_E2E_PHASE core_resource_admin.begin');
      final app = await AppHarness.start(
        connected: true,
        coreSource: true,
        coreResourceAdmin: true,
      );
      final core = app.server.coreAccount!;
      final resources = core.adminResources!;
      final id = '1' * 32;
      Finder key(String name) => find.byKey(ValueKey(name));
      final row = key('home-resource-admin-row-$id');
      const originalLabel = 'Fixture managed room';
      const renamedLabel = 'Fixture room renamed';

      Future<void> waitEnabled(String name) async {
        final button = key(name);
        await waitFor(tester, button);
        await waitUntil(
          tester,
          () =>
              button.evaluate().isNotEmpty &&
              tester.widget<CupertinoButton>(button).onPressed != null,
        );
      }

      Future<void> press(String name) async {
        await waitEnabled(name);
        await tapVisible(tester, key(name));
      }

      Future<void> unlock() async {
        await waitFor(tester, find.text('Unlock'));
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
      }

      void noHomeEffects() {
        expect(app.server.requests, 0);
        expect(app.server.rejectedLogins, 0);
        expect(app.server.acceptedActions, isEmpty);
        expect(app.wsClientsCreated, 0);
        expect(app.server.subscriptions, 0);
        expect(core.rejectedRequests, 0);
      }

      try {
        final preferences = await SharedPreferences.getInstance();
        final legacy = preferences.getString('dashboard_layout');
        await app.mount(tester);
        await waitFor(tester, find.byType(CoreHomeStatusScreen));
        expect(key('home-resources-manage'), findsNothing);
        expect(resources.reads, 0);
        expect(resources.mutations, isEmpty);
        noHomeEffects();
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
        await waitFor(tester, key('home-resources-manage'));
        expect(core.logins, 1);
        expect(core.contextReads, 1);
        expect(core.user['role'], 'admin');
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.account_verified');

        await press('home-resources-manage');
        await waitFor(tester, find.text('Unlock'));
        expect(key('home-resource-admin'), findsNothing);
        await tester.enterText(find.byType(CupertinoTextField), '0000');
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.text('Incorrect PIN'));
        expect(resources.mutations, isEmpty);
        expect(key('home-resource-admin'), findsNothing);
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.wrong_pin_denied');
        await unlock();
        await waitEnabled('home-resource-admin-create');
        expect(key('home-resource-admin'), findsOneWidget);
        expect(resources.mutations, isEmpty);
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.pin_unlocked');

        await press('home-resource-admin-create');
        await press('home-resource-kind-room');
        await tester.enterText(key('home-resource-label'), originalLabel);
        await tester.enterText(key('home-resource-order'), '7');
        expect(resources.mutations, isEmpty);
        await press('home-resource-save');
        await waitFor(tester, key('home-resource-mutation-saved'));
        await waitFor(tester, row);
        expect(find.text(originalLabel), findsOneWidget);
        expect(resources.mutations, ['POST']);
        expect(resources.records.single['label'], originalLabel);
        expect(resources.records.single['order'], 7);
        expect(resources.records.single['revision'], 1);
        expect(resources.records.single['aclRevision'], 1);
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.created');

        await press('home-resource-edit-$id');
        await tester.enterText(key('home-resource-label'), renamedLabel);
        await tester.enterText(key('home-resource-order'), '2');
        await press('home-resource-save');
        await waitFor(tester, key('home-resource-mutation-saved'));
        await waitFor(tester, find.text(renamedLabel));
        expect(find.text(originalLabel), findsNothing);
        expect(row, findsOneWidget);
        expect(resources.mutations, ['POST', 'PATCH']);
        expect(resources.records.single['label'], renamedLabel);
        expect(resources.records.single['order'], 2);
        expect(resources.records.single['revision'], 2);
        expect(resources.records.single['aclRevision'], 1);
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.renamed_reordered');

        await press('home-resource-delete-$id');
        await waitFor(tester, key('home-resource-delete-confirmation'));
        expect(resources.mutations, ['POST', 'PATCH']);
        await press('home-resource-cancel-edit');
        expect(key('home-resource-delete-confirmation'), findsNothing);
        expect(row, findsOneWidget);
        expect(resources.records.single['label'], renamedLabel);
        expect(resources.mutations, ['POST', 'PATCH']);
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.delete_cancelled');
        await press('home-resource-delete-$id');
        await waitFor(tester, key('home-resource-delete-confirmation'));
        expect(resources.mutations, ['POST', 'PATCH']);
        await press('home-resource-confirm-delete');
        await waitFor(tester, key('home-resource-mutation-deleted'));
        expect(row, findsNothing);
        expect(find.text(renamedLabel), findsNothing);
        expect(resources.records, isEmpty);
        expect(resources.mutations, ['POST', 'PATCH', 'DELETE']);
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.delete_confirmed');

        await press('home-resource-admin-back');
        // Wait for the automatic return-to-route read to finish before taking
        // the counter baseline; only the explicit refresh may advance it.
        await waitEnabled('home-resources-refresh');
        final beforeRefresh = resources.reads;
        await press('home-resources-refresh');
        await waitUntil(tester, () => resources.reads > beforeRefresh);
        await waitFor(tester, key('home-resources-empty'));
        expect(key('home-resource-admin'), findsNothing);
        expect(find.text(originalLabel), findsNothing);
        expect(find.text(renamedLabel), findsNothing);
        expect(resources.mutations, ['POST', 'PATCH', 'DELETE']);
        await preferences.reload();
        expect(preferences.getString('dashboard_layout'), legacy);
        noHomeEffects();
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.fresh_empty_read');
      } finally {
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.cleanup_begin');
        await app.close(tester);
        debugPrint('LARENOR_E2E_PHASE core_resource_admin.cleanup_complete');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
