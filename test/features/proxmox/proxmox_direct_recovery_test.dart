import 'dart:async';

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
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/discovery/lan_discovery_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/direct_home_boundary_test.dart' show SecurePlatform;
import '../../core/direct_proxmox_boundary_test.dart'
    show proxmoxHome, proxmoxFields, proxmoxMarker, proxmoxStorageChannel;
import 'proxmox_providers_test.dart' show ControlledConnection;
import 'proxmox_transport_security_test.dart' show authResponse, dataResponse;

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
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = const Size(700, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, body) => AppInteractionScope(
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
        if (find.byType(CupertinoTextFormFieldRow).evaluate().length == 5)
          await fill(tester);
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
          .catchError((Object_) => null);
      expect(held(), isFalse);
      await finish(tester, c);
    },
  );
}
