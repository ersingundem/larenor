import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_access_point.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_port_forward.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_router_status.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_home_screen.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_port_forwarding_screen.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_wifi_screen.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _config = KeeneticConfig(
  baseUrl: 'https://router.test',
  username: 'operator',
  password: 'fixture-only',
);

class _Connection extends KeeneticConnection {
  @override
  Future<KeeneticConfig?> build() async => _config;

  void replace() => state = const AsyncData(
    KeeneticConfig(
      baseUrl: 'https://replacement.test',
      username: 'replacement',
      password: 'fixture-only',
    ),
  );
}

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  required Locale locale,
  required double width,
  AppInteractionController? interaction,
  Future<List<KeeneticAccessPoint>>? accessPoints,
  Future<List<KeeneticPortForward>>? rules,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final monitor = HealthMonitor();
  final health = monitor.bind(
    IntegrationId.keenetic,
    configured: true,
    configurationIdentity: _config,
  )..readSucceeded();
  addTearDown(health.close);
  addTearDown(monitor.dispose);
  final client = KeeneticClient(
    config: _config,
    httpClient: MockClient((_) async => http.Response('{}', 200)),
  );
  addTearDown(client.dispose);
  final controller = interaction ?? AppInteractionController();
  if (interaction == null) addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        healthMonitorProvider.overrideWithValue(monitor),
        keeneticConnectionProvider.overrideWith(_Connection.new),
        keeneticClientProvider.overrideWith((_) async => client),
        keeneticRouterStatusProvider.overrideWith(
          (_) async => const KeeneticRouterStatus(
            model: 'Keenetic Giga',
            hostname: 'home-router',
            firmware: '4.3',
            cpuPercent: 8,
            memoryUsedKiB: 64,
            memoryTotalKiB: 256,
            uptimeSeconds: 3600,
          ),
        ),
        keeneticDevicesProvider.overrideWith((_) async => const []),
        keeneticAccessPointsProvider.overrideWith(
          (_) =>
              accessPoints ??
              Future.value(const [
                KeeneticAccessPoint(
                  id: 'WifiMaster0/AccessPoint0',
                  name: 'Home Wi-Fi',
                  ssid: 'Home',
                  up: true,
                ),
              ]),
        ),
        keeneticPortForwardingProvider.overrideWith(
          (_) =>
              rules ??
              Future.value(const [
                KeeneticPortForward(
                  protocol: 'tcp',
                  port: '8123',
                  toAddress: '192.0.2.10',
                  comment: 'Home Assistant',
                ),
              ]),
        ),
      ],
      child: AppInteractionScope(
        controller: controller,
        child: CupertinoApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: child,
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(Duration.zero);
  }
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      for (final surface in const [
        (
          name: 'home',
          widget: KeeneticHomeScreen(),
          actionKey: 'keenetic-home-wifi',
        ),
        (
          name: 'wifi',
          widget: KeeneticWifiScreen(),
          actionKey: 'keenetic-wifi-refresh',
        ),
        (
          name: 'ports',
          widget: KeeneticPortForwardingScreen(),
          actionKey: 'keenetic-ports-refresh',
        ),
      ]) {
        testWidgets(
          '${surface.name} ${locale.languageCode} ${width.toInt()} 2x uses the shared tablet surface',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              await _mount(
                tester,
                surface.widget,
                locale: locale,
                width: width,
              );
              expect(find.byType(ServiceRootScaffold), findsOneWidget);
              expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
              final l10n = AppLocalizations.of(
                tester.element(find.byType(ServiceRootScaffold)),
              );
              final evidence = find.byKey(
                const ValueKey('health-status-keenetic'),
              );
              expect(
                tester.getSemantics(evidence).label,
                contains(l10n.healthReadCurrent),
              );
              final action = find.byKey(ValueKey(surface.actionKey));
              final node = tester.getSemantics(action);
              expect(node.flagsCollection.isButton, isTrue);
              expect(node.rect.width, greaterThanOrEqualTo(48));
              expect(node.rect.height, greaterThanOrEqualTo(48));
              if (surface.name == 'wifi') {
                final toggle = find.byKey(
                  const ValueKey(
                    'keenetic-wifi-toggle-WifiMaster0/AccessPoint0',
                  ),
                );
                final toggleNode = tester.getSemantics(toggle);
                expect(toggleNode.rect.height, greaterThanOrEqualTo(48));
                expect(
                  toggleNode.flagsCollection.isToggled,
                  ui.Tristate.isTrue,
                );
              }
              final text = find.descendant(
                of: action,
                matching: find.byType(Text),
              );
              final focusTarget = text.evaluate().isNotEmpty
                  ? text.first
                  : find
                        .descendant(of: action, matching: find.byType(Icon))
                        .first;
              Focus.of(tester.element(focusTarget)).requestFocus();
              await tester.pump();
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }

  testWidgets('Wi-Fi and port routes announce loading, empty and error alone', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final accessGate = Completer<List<KeeneticAccessPoint>>();
    await _mount(
      tester,
      const KeeneticWifiScreen(),
      locale: const Locale('en'),
      width: 600,
      accessPoints: accessGate.future,
    );
    final loading = find.byKey(const ValueKey('keenetic-wifi-loading'));
    expect(loading, findsOneWidget);
    expect(tester.getSemantics(loading).flagsCollection.isLiveRegion, isTrue);
    expect(find.text('No access points found'), findsNothing);

    accessGate.complete(const []);
    await tester.pumpAndSettle();
    final empty = find.byKey(const ValueKey('keenetic-wifi-empty'));
    expect(empty, findsOneWidget);
    expect(tester.getSemantics(empty).flagsCollection.isLiveRegion, isTrue);
    expect(find.byKey(const ValueKey('keenetic-wifi-loading')), findsNothing);

    final portGate = Completer<List<KeeneticPortForward>>();
    await _mount(
      tester,
      const KeeneticPortForwardingScreen(),
      locale: const Locale('en'),
      width: 600,
      rules: portGate.future,
    );
    portGate.completeError(StateError('private fixture failure'));
    await tester.pump();
    await tester.pump();
    final error = find.byKey(const ValueKey('keenetic-ports-error'));
    expect(error, findsOneWidget);
    expect(tester.getSemantics(error).flagsCollection.isLiveRegion, isTrue);
    expect(find.textContaining('private fixture failure'), findsNothing);
    expect(find.text('No forwarding rules'), findsNothing);
    semantics.dispose();
  });

  testWidgets('old home action cannot cross account and interaction epochs', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(
      tester,
      const KeeneticHomeScreen(),
      locale: const Locale('en'),
      width: 600,
      interaction: interaction,
    );
    final action = find.byKey(const ValueKey('keenetic-home-wifi'));
    final stale = tester.widget<CupertinoButton>(action).onPressed!;
    final container = ProviderScope.containerOf(tester.element(action));
    (container.read(keeneticConnectionProvider.notifier) as _Connection)
        .replace();
    interaction.setActive(false);
    interaction.setActive(true);
    await tester.pumpAndSettle();
    stale();
    await tester.pumpAndSettle();
    expect(find.byType(KeeneticWifiScreen), findsNothing);
  });
}
