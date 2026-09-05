import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/backup/data/backup_codec.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/presentation/home_dashboard_screen.dart';
import 'package:larenor/features/navigation/presentation/destination_screens.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/features/settings/data/screen_program_store.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';

import 'support/app_harness.dart';
import 'support/synthetic_ha_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'cold start → rejected login → dashboard → routines → PIN protected settings',
    (tester) async {
      final app = await AppHarness.start();
      try {
        await app.mount(tester);
        await waitFor(tester, find.byType(ConnectScreen));
        final inputs = find.byType(CupertinoTextField);
        await tester.enterText(inputs.at(0), app.server.baseUrl);
        await tester.enterText(inputs.at(1), 'synthetic-rejected-token');
        await tapVisible(
          tester,
          find.widgetWithText(CupertinoButton, 'Connect'),
        );
        await waitFor(tester, find.text('Invalid or expired access token.'));
        expect(app.server.rejectedLogins, 1);
        expect(find.byType(HomeDashboardScreen), findsNothing);
        await tester.enterText(inputs.at(1), SyntheticHaServer.token);
        await tapVisible(
          tester,
          find.widgetWithText(CupertinoButton, 'Connect'),
        );
        await waitFor(tester, find.text('Fixture temperature'));
        expect(app.server.reads, contains('/api/states'));
        expect(app.server.subscriptions, greaterThan(0));
        await tapVisible(
          tester,
          find.descendant(
            of: find.byType(CupertinoTabBar),
            matching: find.text('Routines'),
          ),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('routine-scene.fixture_evening')),
        );
        await waitFor(tester, find.byType(EntityDestinationScreen));
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
            of: find.byType(CupertinoTabBar),
            matching: find.text('System'),
          ),
        );
        await waitFor(tester, find.text('Home Assistant'));
        await tapVisible(
          tester,
          find.descendant(
            of: find.byType(CupertinoTabBar),
            matching: find.text('Media'),
          ),
        );
        await tapVisible(
          tester,
          find.descendant(
            of: find.byType(CupertinoTabBar),
            matching: find.text('Home'),
          ),
        );
        await waitFor(tester, find.text('Fixture temperature'));
        await tapVisible(tester, find.byKey(const ValueKey('global-settings')));
        await waitFor(tester, find.text('Unlock'));
        expect(find.byType(BackupScreen), findsNothing);
        await tester.enterText(find.byType(CupertinoTextField), '0000');
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.text('Incorrect PIN'));
        expect(find.text('Backup & Restore'), findsNothing);
        await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
        await tapVisible(tester, find.text('Unlock'));
        await waitFor(tester, find.byType(SettingsSplitScreen));
        await tester.pageBack();
        await tester.pump(const Duration(milliseconds: 400));
        await tapVisible(tester, find.byKey(const ValueKey('global-settings')));
        await waitFor(tester, find.text('Unlock'));
        expect(
          find.text('Backup & Restore'),
          findsNothing,
          reason: 'Leaving Settings drops unlock authority',
        );
      } finally {
        await app.close(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'encrypted vault → cancelled picker → wrong password → preview → local restore and fresh PIN',
    (tester) async {
      final app = await AppHarness.start(connected: true);
      try {
        await app.mount(tester);
        await waitFor(tester, find.text('Fixture temperature'));
        await openSettings(tester);
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
        expect(find.text('Backup & Restore'), findsNothing);
      } finally {
        await app.close(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'fixture light command → accepted receipt → fresh WS state confirmation',
    (tester) async {
      final app = await AppHarness.start(connected: true);
      app.server.allowLightActions = true;
      try {
        await app.mount(tester);
        await waitFor(tester, find.text('Fixture temperature'));
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
        expect(app.server.entities[1]['state'], 'on');
        expect(app.server.acceptedActions, [
          'light.turn_on',
        ], reason: 'No retry or duplicate write');
      } finally {
        await app.close(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'PIN settings → weekly schedule → explicit save → new app scope preserves schedule',
    (tester) async {
      final app = await AppHarness.start(connected: true);
      try {
        await app.mount(tester);
        await waitFor(tester, find.text('Fixture temperature'));
        await openSettings(tester);
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
        await tapVisible(
          tester,
          find.byKey(const ValueKey('screen-program-enabled')),
        );
        final saved = await PreferenceScreenProgramStore().read();
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
        await waitFor(tester, find.text('Fixture temperature'));
        await openSettings(tester);
        await tapVisible(tester, find.text('Display & Brightness'));
        await tapVisible(tester, find.text('Screen schedule'));
        await waitFor(tester, find.text('Fixture weekdays'));
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
        await app.close(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
