import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NoDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async {}
}

class EmptyStore implements ServerSessionPersistence {
  int reads = 0;
  @override
  Future<ServerSession?> read() async {
    reads++;
    return null;
  }

  @override
  Future<void> write(ServerSession? value) async {}
}

class PendingPin extends PinLockStore {
  final readResult = Completer<String?>();
  @override
  Future<String?> read() => readResult.future;
}

Future<void> mount(
  WidgetTester tester,
  Widget home,
  EmptyStore store, {
  String? pin,
  PinLockStore? pinStore,
}) async {
  FlutterSecureStorage.setMockInitialValues({'settings_pin': ?pin});
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(650, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final account = ServerAccountController(store: store);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haDiscoveryFactoryProvider.overrideWithValue(NoDiscovery.new),
        serverAccountControllerProvider.overrideWithValue(account),
        if (pinStore != null) pinLockStoreProvider.overrideWithValue(pinStore),
      ],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 7));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    account.dispose();
  });
}

Future<void> openEntry(WidgetTester tester) async {
  final entry = find.byKey(const ValueKey('connect-larenor-server'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets(
    'captured Connect server entry is expired by background and resume',
    (tester) async {
      final store = EmptyStore();
      await mount(tester, const ConnectScreen(), store);
      final old = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('connect-larenor-server')),
          )
          .onPressed!;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      old();
      await tester.pumpAndSettle();
      expect(find.byType(ServerConnectionScreen), findsNothing);
      expect(store.reads, 0);
      await openEntry(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
    },
  );
  testWidgets(
    'Connect server entry goes through Settings PIN when configured',
    (tester) async {
      final store = EmptyStore();
      await mount(tester, const ConnectScreen(), store, pin: '2468');
      await openEntry(tester);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsGateScreen), findsOneWidget);
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.byType(ServerConnectionScreen), findsNothing);
      expect(store.reads, 0);
      await tester.enterText(find.byType(CupertinoTextField).last, '2468');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Larenor Server'));
      await tester.pumpAndSettle();
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      expect(store.reads, 1);
    },
  );
  testWidgets(
    'fresh Connect opens Server form without starting a network login',
    (tester) async {
      final store = EmptyStore();
      await mount(tester, const ConnectScreen(), store);
      await openEntry(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('server-sign-in')), findsOneWidget);
      expect(store.reads, 1);
    },
  );
  testWidgets(
    'Server settings category does not load account before selection',
    (tester) async {
      final store = EmptyStore();
      await mount(tester, const SettingsSplitScreen(), store);
      expect(store.reads, 0);
      await tester.tap(find.text('Larenor Server'));
      await tester.pumpAndSettle();
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      expect(store.reads, 1);
    },
  );
  testWidgets(
    'background during PIN lookup cannot push an unguarded server route',
    (tester) async {
      final store = EmptyStore(), pin = PendingPin();
      await mount(tester, const ConnectScreen(), store, pinStore: pin);
      await openEntry(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      pin.readResult.complete(null);
      await tester.pump();
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(ServerConnectionScreen), findsNothing);
      expect(store.reads, 0);
    },
  );
}
