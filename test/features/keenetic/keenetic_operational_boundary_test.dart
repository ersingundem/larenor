import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The app's pinned secure-storage plugin owns this public platform test seam.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
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
  if (request.url.path.endsWith('/auth')) {
    return http.Response(
      '',
      200,
      headers: {'set-cookie': 'session=synthetic; Path=/'},
    );
  }
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
  if (request.url.path.endsWith('/ip/static')) {
    return http.Response(
      '[{"protocol":"tcp","port":8123,"to":"192.0.2.7","comment":"Synthetic rule"}]',
      200,
    );
  }
  if (request.url.path.endsWith('/version')) {
    return http.Response('{"model":"Synthetic router","release":"1.0"}', 200);
  }
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
    'reload',
    'logout',
    'dispose',
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
            } else if (change == 'reload') {
              c.invalidate(keeneticConnectionProvider);
            } else if (change == 'logout') {
              await c.read(keeneticConnectionProvider.notifier).signOut();
            } else if (change == 'dispose') {
              await tester.pumpWidget(const SizedBox());
            } else {
              await home.choose(HomeSource.verifiedCore);
            }
            await settle(tester);
            old();
            await settle(tester);
            expect(requests.where((r) => r.method == 'POST'), isEmpty);
            expect(find.byType(CupertinoAlertDialog), findsNothing);
            expect(tester.takeException(), isNull);
            if ([
              'native_focus',
              'idle',
              'background',
              'ticker',
              'covered',
              'reload',
            ].contains(change)) {
              await tester.tap(find.byType(CupertinoSwitch));
              await settle(tester);
              await tester.tap(find.text('Turn Off'));
              await settle(tester);
              expect(requests.where((r) => r.method == 'POST'), hasLength(1));
            }
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
            final fresh = tester
                .widgetList<CupertinoButton>(find.byType(CupertinoButton))
                .firstWhere(
                  (b) =>
                      b.child is Icon &&
                      (b.child as Icon).icon == CupertinoIcons.refresh,
                )
                .onPressed!;
            fresh();
            await settle(tester);
            expect(requests, greaterThan(before));
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

  for (final child in [
    const KeeneticWifiScreen(),
    const KeeneticDevicesScreen(),
    const KeeneticPortForwardingScreen(),
  ]) {
    for (final mode in ['core', 'pending', 'error']) {
      testWidgets(
        '${child.runtimeType} $mode reads no credentials and sends no HTTP',
        (tester) async {
          final (c, _) = await routinesHome(mode);
          final interaction = AppInteractionController();
          addTearDown(interaction.dispose);
          var requests = 0;
          await http.runWithClient(
            () async {
              await mount(tester, c, interaction, child: child);
              expect(secure.calls, isEmpty);
              expect(requests, 0);
              expect(find.byType(CupertinoSwitch), findsNothing);
              expect(find.text('Synthetic device'), findsNothing);
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
  }

  for (final result in ['success', 'unauthorized', 'transport']) {
    testWidgets(
      'late command $result after native focus loss cannot retry, refresh or open an error',
      (tester) async {
        final (c, _) = await routinesHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        final response = Completer<http.Response>();
        final requests = <http.Request>[];
        await http.runWithClient(
          () async {
            await mount(
              tester,
              c,
              interaction,
              child: const IdleGate(child: KeeneticWifiScreen()),
            );
            await tester.tap(find.byType(CupertinoSwitch));
            await settle(tester);
            final confirm = tester
                .widget<CupertinoDialogAction>(
                  find.widgetWithText(CupertinoDialogAction, 'Turn Off'),
                )
                .onPressed!;
            confirm();
            await settle(tester);
            expect(requests.where((r) => r.method == 'POST'), hasLength(1));
            focus(tester, ViewFocusState.unfocused);
            await settle(tester);
            final before = requests.length;
            if (result == 'transport') {
              response.completeError(
                http.ClientException('synthetic unavailable'),
              );
            } else {
              response.complete(
                http.Response('', result == 'success' ? 200 : 401),
              );
            }
            await settle(tester);
            focus(tester, ViewFocusState.focused);
            await settle(tester);
            confirm();
            await settle(tester);
            expect(requests.length, before);
            expect(find.byType(CupertinoAlertDialog), findsNothing);
            expect(tester.takeException(), isNull);
            await finish(tester, c);
          },
          () => MockClient((r) {
            requests.add(r);
            return r.method == 'POST'
                ? response.future
                : Future.value(responseFor(r));
          }),
        );
      },
    );
  }

  testWidgets('unrelated native view focus preserves a current confirmation', (
    tester,
  ) async {
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
          child: const IdleGate(child: KeeneticWifiScreen()),
        );
        await tester.tap(find.byType(CupertinoSwitch));
        await settle(tester);
        tester.binding.handleViewFocusChanged(
          ViewFocusEvent(
            viewId: tester.view.viewId + 999,
            state: ViewFocusState.unfocused,
            direction: ViewFocusDirection.undefined,
          ),
        );
        await settle(tester);
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        await tester.tap(find.text('Turn Off'));
        await settle(tester);
        expect(requests.where((r) => r.method == 'POST'), hasLength(1));
        await finish(tester, c);
      },
      () => MockClient((r) async {
        requests.add(r);
        return responseFor(r);
      }),
    );
  });

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          '$locale $width ${dark ? 'dark' : 'light'} 2x real-font Wi-Fi dialog stays readable and keyboard-cancellable',
          (tester) async {
            await tester.runAsync(() async {
              final data = await rootBundle.load(
                'assets/fonts/Inter-Variable.ttf',
              );
              for (final family in [
                'Inter',
                'CupertinoSystemText',
                'CupertinoSystemDisplay',
              ]) {
                await (FontLoader(family)..addFont(Future.value(data))).load();
              }
            });
            final (c, _) = await routinesHome('direct');
            final interaction = AppInteractionController();
            addTearDown(interaction.dispose);
            var commands = 0;
            final semantics = tester.ensureSemantics();
            await http.runWithClient(
              () async {
                await mount(
                  tester,
                  c,
                  interaction,
                  size: Size(width, 800),
                  scale: 2,
                  locale: Locale(locale),
                  child: CupertinoTheme(
                    data: larenorTheme(
                      brightness: dark ? Brightness.dark : Brightness.light,
                    ),
                    child: const KeeneticWifiScreen(),
                  ),
                );
                await tester.tap(find.byType(CupertinoSwitch));
                await settle(tester);
                final l10n = AppLocalizations.of(
                  tester.element(find.byType(CupertinoAlertDialog)),
                );
                expect(
                  find.text(l10n.keeneticDisableWifiTitle),
                  findsOneWidget,
                );
                final cancel = find.widgetWithText(
                  CupertinoDialogAction,
                  l10n.commonCancel,
                );
                final turnOff = find.widgetWithText(
                  CupertinoDialogAction,
                  l10n.keeneticTurnOff,
                );
                expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
                expect(
                  tester.getSize(turnOff).height,
                  greaterThanOrEqualTo(48),
                );
                await tester.sendKeyEvent(LogicalKeyboardKey.escape);
                await settle(tester);
                expect(find.byType(CupertinoAlertDialog), findsNothing);
                expect(commands, 0);
                expect(tester.takeException(), isNull);
                semantics.dispose();
                await finish(tester, c);
              },
              () => MockClient((r) async {
                if (r.method == 'POST') commands++;
                return responseFor(r);
              }),
            );
          },
        );
      }
    }
  }

  testWidgets(
    'a consumed Wi-Fi confirmation cannot pop the child route or dispatch twice',
    (tester) async {
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      final pending = Completer<http.Response>();
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          await mount(
            tester,
            c,
            interaction,
            child: Builder(
              builder: (context) => CupertinoPageScaffold(
                child: CupertinoButton(
                  onPressed: () => Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => const KeeneticWifiScreen(),
                    ),
                  ),
                  child: const Text('Open child'),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open child'));
          await settle(tester);
          await tester.tap(find.byType(CupertinoSwitch));
          await settle(tester);
          final confirm = tester
              .widget<CupertinoDialogAction>(
                find.widgetWithText(CupertinoDialogAction, 'Turn Off'),
              )
              .onPressed!;
          confirm();
          await tester.pump();
          confirm();
          await settle(tester);
          expect(requests.where((r) => r.method == 'POST'), hasLength(1));
          expect(find.byType(KeeneticWifiScreen), findsOneWidget);
          pending.complete(http.Response('', 200));
          await settle(tester);
          expect(tester.takeException(), isNull);
          await finish(tester, c);
        },
        () => MockClient((r) {
          requests.add(r);
          return r.method == 'POST'
              ? pending.future
              : Future.value(responseFor(r));
        }),
      );
    },
  );

  testWidgets(
    'a retained Direct container cannot authorize a child reparented to Core',
    (tester) async {
      final (direct, _) = await routinesHome('direct');
      final (core, _) = await routinesHome('core');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      final key = GlobalKey();
      final child = KeeneticWifiScreen(key: key);
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          await mount(tester, direct, interaction, child: child);
          final element = key.currentContext;
          final old = tester
              .widget<CupertinoSwitch>(find.byType(CupertinoSwitch))
              .onChanged!;
          final lease = direct.listen(keeneticClientProvider, (_, _) {});
          addTearDown(lease.close);
          final ready = lease.read().value;
          expect(ready, isNotNull);
          final before = requests.length;
          secure.calls.clear();
          await mount(tester, core, interaction, child: child);
          expect(key.currentContext, same(element));
          expect(direct.read(keeneticClientProvider).value, same(ready));
          old(false);
          await settle(tester);
          expect(requests.length, before);
          expect(secure.calls, isEmpty);
          expect(find.byType(CupertinoAlertDialog), findsNothing);
          expect(find.byType(CupertinoSwitch), findsNothing);
          expect(tester.takeException(), isNull);
          await finish(tester, core);
          direct.dispose();
        },
        () => MockClient((r) async {
          requests.add(r);
          return responseFor(r);
        }),
      );
    },
  );

  testWidgets('invalid interface observation never offers a command', (
    tester,
  ) async {
    final (c, _) = await routinesHome('direct');
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    var commands = 0;
    await http.runWithClient(
      () async {
        await mount(tester, c, interaction, child: const KeeneticWifiScreen());
        expect(
          tester
              .widget<CupertinoSwitch>(find.byType(CupertinoSwitch))
              .onChanged,
          isNull,
        );
        await tester.tap(find.byType(CupertinoSwitch));
        await settle(tester);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(commands, 0);
        await finish(tester, c);
      },
      () => MockClient((r) async {
        if (r.method == 'POST') commands++;
        if (r.url.path.endsWith('/show/interface')) {
          return http.Response(
            '{"Other0":{"type":"AccessPoint","description":"Synthetic unsupported interface","state":"up"}}',
            200,
          );
        }
        return responseFor(r);
      }),
    );
  });

  testWidgets(
    'active command failure remains explicit and an expired error action cannot pop a route',
    (tester) async {
      final (c, _) = await routinesHome('direct');
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      var commands = 0;
      await http.runWithClient(
        () async {
          await mount(
            tester,
            c,
            interaction,
            child: const KeeneticWifiScreen(),
          );
          await tester.tap(find.byType(CupertinoSwitch));
          await settle(tester);
          await tester.tap(find.text('Turn Off'));
          await settle(tester);
          expect(commands, 1);
          expect(find.text('Error'), findsOneWidget);
          expect(find.textContaining('private-device-payload'), findsNothing);
          final old = tester
              .widget<CupertinoDialogAction>(
                find.widgetWithText(CupertinoDialogAction, 'OK'),
              )
              .onPressed!;
          interaction.setActive(false);
          await settle(tester);
          interaction.setActive(true);
          await settle(tester);
          old();
          await settle(tester);
          expect(find.byType(KeeneticWifiScreen), findsOneWidget);
          expect(find.byType(CupertinoAlertDialog), findsNothing);
          expect(commands, 1);
          expect(tester.takeException(), isNull);
          await finish(tester, c);
        },
        () => MockClient((r) async {
          if (r.method == 'POST') {
            commands++;
            return http.Response('private-device-payload', 401);
          }
          return responseFor(r);
        }),
      );
    },
  );
}
