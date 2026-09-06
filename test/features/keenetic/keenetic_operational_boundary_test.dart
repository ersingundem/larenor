import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// The app's pinned secure-storage plugin owns this public platform test seam.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_devices_screen.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_port_forwarding_screen.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_wifi_screen.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/settings/presentation/idle_gate.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/direct_home_boundary_test.dart' show SecurePlatform;
import '../../core/direct_home_routines_test.dart' show routinesHome;
import '../../core/direct_keenetic_boundary_test.dart' show keeneticRecord;
import 'keenetic_direct_recovery_test.dart' show tap;
import '../media/qbittorrent/qbittorrent_direct_recovery_test.dart'
    show mount, settle, finish;

const storageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

http.Response responseFor(http.Request request) {
  if (request.url.path.endsWith('/auth'))
    return http.Response(
      '',
      200,
      headers: {'set-cookie': 'session=synthetic; Path=/'},
    );
  if (request.method == 'POST') return http.Response('', 200);
  if (request.url.path.endsWith('/show/interface')) {
    return http.Response(
      jsonEncode({
        'WifiMaster0/AccessPoint0': {
          'type': 'AccessPoint',
          'description': 'Synthetic Wi-Fi',
          'ssid': 'Synthetic SSID',
          'state': 'up',
        },
      }),
      200,
    );
  }
  if (request.url.path.endsWith('/hotspot')) {
    return http.Response(
      '{"host":[{"mac":"02:00:00:00:00:01","name":"Synthetic device","ip":"192.0.2.7","active":true}]}',
      200,
    );
  }
  if (request.url.path.endsWith('/ip/static'))
    return http.Response(
      '[{"protocol":"tcp","port":8123,"to":"192.0.2.7","comment":"Synthetic rule"}]',
      200,
    );
  if (request.url.path.endsWith('/version'))
    return http.Response('{"model":"Synthetic router","release":"1.0"}', 200);
  return http.Response('{}', 200);
}

void focus(WidgetTester tester, ViewFocusState state) =>
    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: state,
        direction: ViewFocusDirection.undefined,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = SecurePlatform()
      ..values.clear()
      ..values.addAll({...keeneticRecord, 'settings_pin': '2468'});
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    messenger.setMockMethodCallHandler(storageChannel, secure.handle);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(storageChannel, null);
    FlutterSecureStoragePlatform.instance = previous;
  });

  for (final change in [
    'native_focus',
    'idle',
    'background',
    'ticker',
    'covered',
    'account',
    'source',
  ]) {
    testWidgets(
      'captured Wi-Fi confirmation after $change cannot dispatch a command',
      (tester) async {
        final (c, home) = await routinesHome('direct');
        final interaction = AppInteractionController();
        final ticker = ValueNotifier(true);
        addTearDown(interaction.dispose);
        addTearDown(ticker.dispose);
        final requests = <http.Request>[];
        await http.runWithClient(
          () async {
            await mount(
              tester,
              c,
              interaction,
              visible: ticker,
              child: change == 'native_focus'
                  ? const IdleGate(child: KeeneticWifiScreen())
                  : const KeeneticWifiScreen(),
            );
            await tester.tap(find.byType(CupertinoSwitch));
            await settle(tester);
            final old = tester
                .widget<CupertinoDialogAction>(
                  find.widgetWithText(CupertinoDialogAction, 'Turn Off'),
                )
                .onPressed!;
            if (change == 'native_focus') {
              focus(tester, ViewFocusState.unfocused);
              await settle(tester);
              focus(tester, ViewFocusState.focused);
            } else if (change == 'idle') {
              interaction.setActive(false);
              await settle(tester);
              interaction.setActive(true);
            } else if (change == 'background') {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await settle(tester);
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
            } else if (change == 'ticker') {
              ticker.value = false;
              await settle(tester);
              ticker.value = true;
            } else if (change == 'covered') {
              final navigator = Navigator.of(
                tester.element(find.byType(KeeneticWifiScreen)),
              );
              unawaited(
                navigator.push(
                  CupertinoPageRoute<void>(
                    builder: (_) => const CupertinoPageScaffold(
                      child: Text('Covered route'),
                    ),
                  ),
                ),
              );
              await settle(tester);
              navigator.pop();
            } else if (change == 'account') {
              secure.values['keenetic_base_url'] =
                  'https://other.invalid/prefix';
              c.invalidate(keeneticConnectionProvider);
            } else {
              await home.choose(HomeSource.verifiedCore);
            }
            await settle(tester);
            old();
            await settle(tester);
            expect(requests.where((r) => r.method == 'POST'), isEmpty);
            expect(find.byType(CupertinoAlertDialog), findsNothing);
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((r) async {
            requests.add(r);
            return responseFor(r);
          }),
        );
      },
    );
  }

  testWidgets(
    'PIN settings fresh Wi-Fi confirmation sends exactly the existing batch',
    (tester) async {
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          await mount(
            tester,
            c,
            interaction,
            child: const IdleGate(child: SettingsGateScreen()),
          );
          expect(requests, isEmpty);
          expect(find.byType(KeeneticWifiScreen), findsNothing);
          await tester.enterText(find.byType(CupertinoTextField), '2468');
          for (final label in [
            'Unlock',
            'Integrations',
            'Manage Integrations',
            'Keenetic',
            'Wi-Fi',
          ]) {
            await tap(tester, label);
          }
          expect(find.byType(KeeneticWifiScreen), findsOneWidget);
          await tester.tap(find.byType(CupertinoSwitch));
          await settle(tester);
          await tester.tap(find.text('Cancel'));
          await settle(tester);
          expect(requests.where((r) => r.method == 'POST'), isEmpty);
          await tester.tap(find.byType(CupertinoSwitch));
          await settle(tester);
          await tester.tap(find.text('Turn Off'));
          await settle(tester);
          final writes = requests.where((r) => r.method == 'POST').toList();
          expect(writes, hasLength(1));
          expect(
            writes.single.url.toString(),
            'https://router.invalid/prefix/rci/',
          );
          expect(jsonDecode(writes.single.body), [
            {'parse': 'interface WifiMaster0/AccessPoint0 down'},
            {'parse': 'system configuration save'},
          ]);
          expect(tester.takeException(), isNull);
          await finish(tester, c);
        },
        () => MockClient((r) async {
          requests.add(r);
          return responseFor(r);
        }),
      );
    },
  );

  for (final child in [
    const KeeneticDevicesScreen(),
    const KeeneticPortForwardingScreen(),
  ]) {
    testWidgets(
      '${child.runtimeType} old refresh after idle sends no extra read',
      (tester) async {
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        var requests = 0;
        await http.runWithClient(
          () async {
            await mount(tester, c, interaction, child: child);
            final old = tester
                .widgetList<CupertinoButton>(find.byType(CupertinoButton))
                .firstWhere(
                  (b) =>
                      b.child is Icon &&
                      (b.child as Icon).icon == CupertinoIcons.refresh,
                )
                .onPressed!;
            interaction.setActive(false);
            await settle(tester);
            interaction.setActive(true);
            await settle(tester);
            final before = requests;
            old();
            await settle(tester);
            expect(requests, before);
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((r) async {
            requests++;
            return responseFor(r);
          }),
        );
      },
    );
  }

  testWidgets(
    'device detail cannot keep former account metadata after replacement',
    (tester) async {
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await http.runWithClient(() async {
        await mount(
          tester,
          c,
          interaction,
          child: const KeeneticDevicesScreen(),
        );
        await tester.tap(find.text('Synthetic device'));
        await settle(tester);
        expect(find.text('02:00:00:00:00:01'), findsOneWidget);
        secure.values['keenetic_base_url'] = 'https://other.invalid/prefix';
        c.invalidate(keeneticConnectionProvider);
        await settle(tester);
        expect(find.text('02:00:00:00:00:01'), findsNothing);
        expect(find.text('192.0.2.7'), findsNothing);
        expect(tester.takeException(), isNull);
        await finish(tester, c);
      }, () => MockClient((r) async => responseFor(r)));
    },
  );
}
