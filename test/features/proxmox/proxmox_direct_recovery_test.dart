import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_connect_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_nodes_screen.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_session_guard.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/discovery/lan_discovery_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/direct_home_boundary_test.dart' show SecurePlatform;
import '../../core/direct_proxmox_boundary_test.dart'
    show proxmoxHome, proxmoxFields, proxmoxMarker, proxmoxStorageChannel;
import 'proxmox_providers_test.dart' show ControlledConnection;
import 'proxmox_transport_security_test.dart' show authResponse, dataResponse;

void focus(WidgetTester tester, bool focused, {bool otherView = false}) =>
    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId + (otherView ? 1 : 0),
        state: focused ? ViewFocusState.focused : ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> click(WidgetTester tester, String text) async {
  final found = find.text(text);
  if (found.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      found,
      250,
      scrollable: find
          .descendant(
            of: find.byType(ProxmoxConnectScreen),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 30,
    );
  }
  await Scrollable.ensureVisible(tester.element(found.first), alignment: .4);
  await frames(tester);
  await tester.tap(found.first);
  await frames(tester);
}

Future<void> fill(WidgetTester tester) async {
  final rows = find.byType(CupertinoTextFormFieldRow);
  for (final pair in [
    'new.invalid',
    '9443',
    'pve',
    'new-user',
    'synthetic-new-password',
  ].indexed) {
    await Scrollable.ensureVisible(
      tester.element(rows.at(pair.$1)),
      alignment: .4,
    );
    await tester.enterText(rows.at(pair.$1), pair.$2);
  }
}

Future<void> mount(
  WidgetTester tester,
  ProviderContainer c,
  AppInteractionController interaction, {
  Widget child = const ProxmoxConnectScreen(),
  ValueNotifier<bool>? visible,
  Size size = const Size(700, 1100),
  Locale locale = const Locale('en'),
  double scale = 1,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: CupertinoApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, body) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: AppInteractionScope(
            controller: interaction,
            child: visible == null
                ? body!
                : ValueListenableBuilder<bool>(
                    valueListenable: visible,
                    child: body,
                    builder: (_, value, child) =>
                        TickerMode(enabled: value, child: child!),
                  ),
          ),
        ),
        home: child,
      ),
    ),
  );
  await frames(tester);
}

Future<void> finish(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
  await frames(tester);
}

class SourceCapture extends ConsumerWidget {
  const SourceCapture(this.capture, {super.key});
  final void Function(bool Function()?) capture;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(proxmoxConnectionProvider);
    // The overridden connection omits production's source subscription.
    ref.watch(directHomeAccessProvider);
    capture(captureProxmoxRouteSource(ref));
    return const SizedBox();
  }
}

void main() {
  late SecurePlatform secure;
  late FlutterSecureStoragePlatform previous;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = SecurePlatform()..values.clear();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    messenger.setMockMethodCallHandler(proxmoxStorageChannel, secure.handle);
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/network_info'),
      (_) async => null,
    );
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    messenger.setMockMethodCallHandler(proxmoxStorageChannel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/network_info'),
      null,
    );
  });
  for (final mode in ['core', 'pending', 'error']) {
    testWidgets(
      '$mode standalone setup never reads credentials or mounts discovery',
      (tester) async {
        secure.values.addAll(proxmoxFields);
        var clients = 0;
        final (c, _) = await proxmoxHome(
          mode,
          factory: (config, health) {
            clients++;
            return ProxmoxClient(
              config: config,
              httpClient: MockClient((_) async => authResponse()),
            );
          },
        );
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        await mount(tester, c, interaction);
        expect(find.byType(LanDiscoverySection), findsNothing);
        expect(secure.calls, isEmpty);
        expect(clients, 0);
        await finish(tester, c);
      },
    );
  }
  for (final action in ['view', 'clear', 'connect']) {
    testWidgets(
      'actual Settings PIN opens pending six-field recovery $action without discovery',
      (tester) async {
        secure.values.addAll(proxmoxFields);
        secure.values[proxmoxMarker] = '1';
        secure.values['settings_pin'] = '2468';
        final requests = <http.Request>[];
        final (c, _) = await proxmoxHome(
          'direct',
          factory: (config, health) => ProxmoxClient(
            config: config,
            healthSession: health,
            httpClient: MockClient((request) async {
              requests.add(request);
              return request.url.path.endsWith('/access/ticket')
                  ? authResponse()
                  : dataResponse([]);
            }),
          ),
        );
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        await mount(tester, c, interaction, child: const SettingsGateScreen());
        await tester.enterText(find.byType(CupertinoTextField).first, '2468');
        await click(tester, 'Unlock');
        await click(tester, 'Integrations');
        await click(tester, 'Manage Integrations');
        await click(tester, 'Proxmox');
        expect(find.byType(ProxmoxConnectScreen), findsOneWidget);
        expect(find.byType(LanDiscoverySection), findsNothing);
        expect(
          tester
              .widgetList<CupertinoTextFormFieldRow>(
                find.byType(CupertinoTextFormFieldRow),
              )
              .map((w) => w.controller!.text),
          everyElement(isEmpty),
        );
        expect(requests, isEmpty);
        if (action == 'clear') {
          await click(tester, 'Remove saved connection');
          expect(secure.values[proxmoxMarker], isNull);
          expect(find.text('Done'), findsOneWidget);
          expect(find.byType(LanDiscoverySection), findsNothing);
          expect(requests, isEmpty);
        }
        if (action == 'connect') {
          await fill(tester);
          await click(tester, 'Connect');
          expect(secure.values[proxmoxMarker], isNull);
          expect(secure.values['proxmox_port'], '9443');
          expect(secure.values['proxmox_allow_self_signed'], 'false');
          expect(requests.take(2).map((r) => r.url.path), [
            '/api2/json/access/ticket',
            '/api2/json/nodes',
          ]);
          expect(requests.first.bodyFields['username'], 'new-user@pve');
          expect(find.byType(ProxmoxConnectScreen), findsNothing);
        }
        await finish(tester, c);
      },
    );
  }
  for (final reason in [
    'window',
    'background',
    'ticker',
    'route',
    'source',
    'dispose',
  ]) {
    testWidgets(
      'held setup callback is inert after $reason even with replacement draft',
      (tester) async {
        var requests = 0;
        final (c, home) = await proxmoxHome(
          'direct',
          factory: (config, health) => ProxmoxClient(
            config: config,
            httpClient: MockClient((request) async {
              requests++;
              return request.url.path.endsWith('/access/ticket')
                  ? authResponse()
                  : dataResponse([]);
            }),
          ),
        );
        final interaction = AppInteractionController(),
            visible = ValueNotifier(true);
        addTearDown(interaction.dispose);
        addTearDown(visible.dispose);
        await mount(tester, c, interaction, visible: visible);
        await fill(tester);
        await Scrollable.ensureVisible(
          tester.element(find.text('Connect')),
          alignment: .4,
        );
        await frames(tester);
        final held = tester
            .widget<CupertinoButton>(
              find.widgetWithText(CupertinoButton, 'Connect'),
            )
            .onPressed!;
        if (reason == 'window') {
          interaction.setActive(false);
          interaction.setActive(true);
        }
        if (reason == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        if (reason == 'ticker') {
          visible.value = false;
          await frames(tester);
          visible.value = true;
        }
        if (reason == 'route') {
          final nav = Navigator.of(
            tester.element(find.byType(ProxmoxConnectScreen)),
          );
          nav.push(
            CupertinoPageRoute(
              builder: (_) => const CupertinoPageScaffold(child: Text('other')),
            ),
          );
          await frames(tester);
          nav.pop();
        }
        if (reason == 'source') {
          await home.choose(HomeSource.verifiedCore);
          await home.choose(HomeSource.directLocal);
          home.runtimeMounted(home.runtimeIdentity);
        }
        if (reason == 'dispose') {
          await tester.pumpWidget(const SizedBox());
        }
        await frames(tester);
        if (find.byType(CupertinoTextFormFieldRow).evaluate().length == 5) {
          await fill(tester);
        }
        secure.calls.clear();
        held();
        await frames(tester);
        expect(requests, 0);
        expect(secure.calls, isEmpty);
        expect(tester.takeException(), isNull);
        await finish(tester, c);
      },
    );
  }
  testWidgets(
    'held route source cannot revive after equal-config source roundtrip',
    (tester) async {
      secure.values.addAll(proxmoxFields);
      final (c, home) = await proxmoxHome(
        'direct',
        connection: ControlledConnection.new,
      );
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      bool Function()? latest;
      await mount(
        tester,
        c,
        interaction,
        child: SourceCapture((value) => latest = value),
      );
      final held = latest!;
      expect(held(), isTrue);
      interaction.setActive(false);
      await frames(tester);
      expect(held(), isTrue);
      await home.choose(HomeSource.verifiedCore);
      await home.choose(HomeSource.directLocal);
      home.runtimeMounted(home.runtimeIdentity);
      await frames(tester);
      await c
          .read(proxmoxConnectionProvider.future)
          .catchError((Object _) => null);
      expect(held(), isFalse);
      await finish(tester, c);
    },
  );

  for (final field in proxmoxFields.keys) {
    testWidgets(
      'window expiry after $field write blocks remaining fields and config publication',
      (tester) async {
        final (c, _) = await proxmoxHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        messenger.setMockMethodCallHandler(proxmoxStorageChannel, (call) async {
          final result = await secure.handle(call);
          if (call.method == 'write' &&
              (call.arguments as Map)['key'] == field) {
            interaction.setActive(false);
          }
          return result;
        });
        await mount(tester, c, interaction);
        await fill(tester);
        await click(tester, 'Connect');
        expect(secure.values[proxmoxMarker], '1');
        final keys = proxmoxFields.keys.toList();
        expect(
          secure.calls
              .where((call) => call.$1 == 'write')
              .map((call) => call.$2),
          [proxmoxMarker, ...keys.take(keys.indexOf(field) + 1)],
        );
        expect(c.read(proxmoxConnectionProvider).hasError, isTrue);
        expect(tester.takeException(), isNull);
        await finish(tester, c);
      },
    );
  }
  for (final reason in [
    'window',
    'background',
    'ticker',
    'route',
    'source',
    'dispose',
  ]) {
    for (final phase in reason == 'window' ? ['ticket', 'nodes'] : ['ticket']) {
      testWidgets(
        '$reason during $phase closes only the owned verifier and sends no later request',
        (tester) async {
          final response = Completer<http.Response>();
          var requests = 0;
          final (c, home) = await proxmoxHome(
            'direct',
            factory: (config, health) => ProxmoxClient(
              config: config,
              httpClient: MockClient((request) async {
                requests++;
                return request.url.path.endsWith(
                      phase == 'ticket' ? '/access/ticket' : '/nodes',
                    )
                    ? response.future
                    : authResponse();
              }),
            ),
          );
          final interaction = AppInteractionController(),
              visible = ValueNotifier(true);
          addTearDown(interaction.dispose);
          addTearDown(visible.dispose);
          await mount(tester, c, interaction, visible: visible);
          await fill(tester);
          await click(tester, 'Connect');
          expect(requests, phase == 'ticket' ? 1 : 2);
          if (reason == 'window') interaction.setActive(false);
          if (reason == 'background') {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          }
          if (reason == 'ticker') visible.value = false;
          if (reason == 'route') {
            Navigator.of(tester.element(find.byType(ProxmoxConnectScreen)))
                .push(
                  CupertinoPageRoute(
                    builder: (_) =>
                        const CupertinoPageScaffold(child: Text('other')),
                  ),
                );
          }
          if (reason == 'source') await home.choose(HomeSource.verifiedCore);
          if (reason == 'dispose') await tester.pumpWidget(const SizedBox());
          await frames(tester);
          response.complete(
            phase == 'ticket' ? authResponse() : dataResponse([]),
          );
          await frames(tester);
          expect(requests, phase == 'ticket' ? 1 : 2);
          expect(secure.calls.where((call) => call.$1 == 'write'), isEmpty);
          expect(tester.takeException(), isNull);
          await finish(tester, c);
        },
      );
    }
  }
  for (final reason in ['window', 'ticker', 'route']) {
    testWidgets('held root refresh cannot restart a reader after $reason', (
      tester,
    ) async {
      secure.values.addAll(proxmoxFields);
      var requests = 0;
      final (c, _) = await proxmoxHome(
        'direct',
        factory: (config, health) => ProxmoxClient(
          config: config,
          healthSession: health,
          httpClient: MockClient((request) async {
            requests++;
            return request.url.path.endsWith('/access/ticket')
                ? authResponse()
                : dataResponse([]);
          }),
        ),
      );
      final interaction = AppInteractionController(),
          visible = ValueNotifier(true);
      addTearDown(interaction.dispose);
      addTearDown(visible.dispose);
      await mount(
        tester,
        c,
        interaction,
        visible: visible,
        child: const ProxmoxNodesScreen(),
      );
      final button = find.ancestor(
        of: find.byIcon(CupertinoIcons.refresh),
        matching: find.byType(CupertinoButton),
      );
      final held = tester.widget<CupertinoButton>(button).onPressed!;
      if (reason == 'window') {
        interaction.setActive(false);
        interaction.setActive(true);
      }
      if (reason == 'ticker') {
        visible.value = false;
        await frames(tester);
        visible.value = true;
      }
      if (reason == 'route') {
        final nav = Navigator.of(
          tester.element(find.byType(ProxmoxNodesScreen)),
        );
        nav.push(
          CupertinoPageRoute(
            builder: (_) => const CupertinoPageScaffold(child: Text('other')),
          ),
        );
        await frames(tester);
        nav.pop();
      }
      await frames(tester);
      final before = requests;
      held();
      await frames(tester);
      expect(requests, before);
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    });
  }
  for (final bad in [
    ('proxmox_allow_self_signed', null),
    ('proxmox_port', 'bad'),
  ]) {
    testWidgets(
      'legacy invalid ${bad.$1} opens blank recovery without granting TLS or login',
      (tester) async {
        secure.values.addAll(proxmoxFields);
        if (bad.$2 == null) {
          secure.values.remove(bad.$1);
        } else {
          secure.values[bad.$1] = bad.$2!;
        }
        var clients = 0;
        final (c, _) = await proxmoxHome(
          'direct',
          factory: (config, health) {
            clients++;
            return ProxmoxClient(
              config: config,
              httpClient: MockClient((_) async => authResponse()),
            );
          },
        );
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        await mount(tester, c, interaction, child: const ProxmoxNodesScreen());
        expect(find.byType(ProxmoxConnectScreen), findsOneWidget);
        expect(find.byType(LanDiscoverySection), findsNothing);
        expect(
          tester
              .widgetList<CupertinoTextFormFieldRow>(
                find.byType(CupertinoTextFormFieldRow),
              )
              .map((w) => w.controller!.text),
          everyElement(isEmpty),
        );
        expect(
          tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
          isFalse,
        );
        expect(clients, 0);
        expect(secure.calls.where((call) => call.$1 != 'read'), isEmpty);
        await finish(tester, c);
      },
    );
  }
  for (final layout in [
    (const Size(320, 640), const Locale('tr')),
    (const Size(1366, 1024), const Locale('en')),
  ]) {
    testWidgets(
      'recovery layout ${layout.$1} ${layout.$2} 2x preserves explicit clear',
      (tester) async {
        secure.values.addAll(proxmoxFields);
        secure.values[proxmoxMarker] = '1';
        final (c, _) = await proxmoxHome('direct');
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        await mount(
          tester,
          c,
          interaction,
          child: const ProxmoxNodesScreen(),
          size: layout.$1,
          locale: layout.$2,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        await click(
          tester,
          layout.$2.languageCode == 'tr'
              ? 'Kayıtlı bağlantıyı kaldır'
              : 'Remove saved connection',
        );
        final scroll = find
            .descendant(
              of: find.byType(ProxmoxConnectScreen),
              matching: find.byType(Scrollable),
            )
            .first;
        tester.state<ScrollableState>(scroll).position.jumpTo(0);
        await frames(tester);
        expect(
          find.text(layout.$2.languageCode == 'tr' ? 'Bitti' : 'Done'),
          findsOneWidget,
        );
        expect(secure.values[proxmoxMarker], isNull);
        expect(tester.takeException(), isNull);
        await finish(tester, c);
      },
    );
  }
  testWidgets(
    'actual PIN change retires in-flight recovery and both captured callbacks',
    (tester) async {
      secure.values.addAll(proxmoxFields);
      secure.values[proxmoxMarker] = '1';
      secure.values['settings_pin'] = '2468';
      final response = Completer<http.Response>();
      var requests = 0;
      final (c, _) = await proxmoxHome(
        'direct',
        factory: (config, health) => ProxmoxClient(
          config: config,
          httpClient: MockClient((_) async {
            requests++;
            return response.future;
          }),
        ),
      );
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, c, interaction, child: const SettingsGateScreen());
      await tester.enterText(find.byType(CupertinoTextField).first, '2468');
      await click(tester, 'Unlock');
      await click(tester, 'Integrations');
      await click(tester, 'Manage Integrations');
      await click(tester, 'Proxmox');
      await fill(tester);
      final clear = find.widgetWithText(
        CupertinoButton,
        'Remove saved connection',
      );
      await Scrollable.ensureVisible(tester.element(clear), alignment: .4);
      await frames(tester);
      final heldClear = tester.widget<CupertinoButton>(clear).onPressed!;
      final connect = find.widgetWithText(CupertinoButton, 'Connect');
      final heldConnect = tester.widget<CupertinoButton>(connect).onPressed!;
      heldConnect();
      await frames(tester);
      expect(requests, 1);
      secure.values['settings_pin'] = '1357';
      c.invalidate(pinLockProvider);
      await frames(tester);
      expect(find.byType(ProxmoxConnectScreen), findsNothing);
      secure.calls.clear();
      heldClear();
      heldConnect();
      response.complete(authResponse());
      await frames(tester);
      expect(requests, 1);
      expect(secure.calls.where((call) => call.$1 != 'read'), isEmpty);
      expect(secure.values[proxmoxMarker], '1');
      expect(
        secure.values['proxmox_password'],
        proxmoxFields['proxmox_password'],
      );
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    },
  );

  for (final phase in ['loading', 'settled']) {
    testWidgets(
      'held setup callback cannot cross provider-only $phase reload',
      (tester) async {
        var requests = 0;
        final (c, _) = await proxmoxHome(
          'direct',
          factory: (config, health) => ProxmoxClient(
            config: config,
            httpClient: MockClient((request) async {
              requests++;
              return request.url.path.endsWith('/access/ticket')
                  ? authResponse()
                  : dataResponse([]);
            }),
          ),
        );
        final interaction = AppInteractionController();
        addTearDown(interaction.dispose);
        await mount(tester, c, interaction);
        await fill(tester);
        final button = find.widgetWithText(CupertinoButton, 'Connect');
        await Scrollable.ensureVisible(tester.element(button), alignment: .4);
        await frames(tester);
        final held = tester.widget<CupertinoButton>(button).onPressed!;
        final before = c.read(proxmoxConnectionProvider.notifier);
        c.invalidate(proxmoxConnectionProvider);
        c.read(proxmoxConnectionProvider);
        if (phase == 'settled') {
          await c.read(proxmoxConnectionProvider.future);
          await frames(tester);
          await fill(tester);
        }
        expect(
          identical(c.read(proxmoxConnectionProvider.notifier), before),
          isTrue,
        );
        secure.calls.clear();
        held();
        await frames(tester);
        expect(requests, 0);
        expect(secure.calls.where((call) => call.$1 != 'read'), isEmpty);
        expect(tester.takeException(), isNull);
        await finish(tester, c);
      },
    );
  }
  testWidgets(
    'provider reload while its form login is pending closes the owned transport',
    (tester) async {
      final response = Completer<http.Response>();
      var requests = 0;
      final (c, _) = await proxmoxHome(
        'direct',
        factory: (config, health) => ProxmoxClient(
          config: config,
          httpClient: MockClient((request) async {
            requests++;
            return request.url.path.endsWith('/access/ticket')
                ? response.future
                : dataResponse([]);
          }),
        ),
      );
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, c, interaction);
      await fill(tester);
      await click(tester, 'Connect');
      expect(requests, 1);
      c.invalidate(proxmoxConnectionProvider);
      c.read(proxmoxConnectionProvider);
      await frames(tester);
      response.complete(authResponse());
      await frames(tester);
      expect(requests, 1);
      expect(secure.calls.where((call) => call.$1 == 'write'), isEmpty);
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    },
  );
  testWidgets(
    'own confirmed-account replacement loading does not cancel its current form',
    (tester) async {
      secure.values.addAll(proxmoxFields);
      var requests = 0;
      final (c, _) = await proxmoxHome(
        'direct',
        factory: (config, health) => ProxmoxClient(
          config: config,
          httpClient: MockClient((request) async {
            requests++;
            return request.url.path.endsWith('/access/ticket')
                ? authResponse()
                : dataResponse([]);
          }),
        ),
      );
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, c, interaction);
      await fill(tester);
      await click(tester, 'Connect');
      expect(requests, 2);
      expect(secure.values['proxmox_host'], 'new.invalid');
      expect(c.read(proxmoxConnectionProvider).hasError, isFalse);
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    },
  );

  testWidgets(
    'native focus retires setup discovery TLS and connect callbacks only for this view',
    (tester) async {
      var requests = 0;
      final (c, _) = await proxmoxHome(
        'direct',
        factory: (config, health) => ProxmoxClient(
          config: config,
          httpClient: MockClient((request) async {
            requests++;
            return request.url.path.endsWith('/access/ticket')
                ? authResponse()
                : dataResponse([]);
          }),
        ),
      );
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, c, interaction);
      await fill(tester);
      final selected = tester
          .widget<LanDiscoverySection>(find.byType(LanDiscoverySection))
          .onSelected;
      final tls = tester
          .widget<CupertinoSwitch>(find.byType(CupertinoSwitch))
          .onChanged!;
      final connect = tester
          .widget<CupertinoButton>(
            find.widgetWithText(CupertinoButton, 'Connect'),
          )
          .onPressed!;
      focus(tester, false, otherView: true);
      await frames(tester);
      tls(true);
      await frames(tester);
      expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isTrue,
      );
      focus(tester, false);
      await frames(tester);
      focus(tester, true);
      await frames(tester);
      await fill(tester);
      secure.calls.clear();
      tls(true);
      selected('https://other.invalid:8443');
      connect();
      await frames(tester);
      expect(requests, 0);
      expect(secure.calls, isEmpty);
      expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isFalse,
      );
      expect(
        tester
            .widget<CupertinoTextFormFieldRow>(
              find.byType(CupertinoTextFormFieldRow).first,
            )
            .controller!
            .text,
        'new.invalid',
      );
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    },
  );
  testWidgets(
    'native focus loss cancels the owned ticket response before node read',
    (tester) async {
      final response = Completer<http.Response>();
      var requests = 0;
      final (c, _) = await proxmoxHome(
        'direct',
        factory: (config, health) => ProxmoxClient(
          config: config,
          httpClient: MockClient((request) async {
            requests++;
            return request.url.path.endsWith('/access/ticket')
                ? response.future
                : dataResponse([]);
          }),
        ),
      );
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, c, interaction);
      await fill(tester);
      await click(tester, 'Connect');
      expect(requests, 1);
      focus(tester, false);
      await frames(tester);
      response.complete(authResponse());
      await frames(tester);
      expect(requests, 1);
      expect(secure.calls.where((call) => call.$1 == 'write'), isEmpty);
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    },
  );
  testWidgets(
    'native focus does not revive held root refresh or interrupt authorized Direct reads',
    (tester) async {
      secure.values.addAll(proxmoxFields);
      var requests = 0;
      final (c, _) = await proxmoxHome(
        'direct',
        factory: (config, health) => ProxmoxClient(
          config: config,
          healthSession: health,
          httpClient: MockClient((request) async {
            requests++;
            return request.url.path.endsWith('/access/ticket')
                ? authResponse()
                : dataResponse([]);
          }),
        ),
      );
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, c, interaction, child: const ProxmoxNodesScreen());
      final held = tester
          .widget<CupertinoButton>(
            find.ancestor(
              of: find.byIcon(CupertinoIcons.refresh),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed!;
      final reader = (await c.read(proxmoxClientProvider.future))!;
      focus(tester, false);
      await frames(tester);
      final beforeRead = requests;
      await reader.getNodes();
      expect(requests, beforeRead + 1);
      focus(tester, true);
      await frames(tester);
      final beforeHeld = requests;
      held();
      await frames(tester);
      expect(requests, beforeHeld);
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    },
  );
}
