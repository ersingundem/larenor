import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/settings/presentation/panes/connection_pane.dart';
import 'package:larenor/features/settings/presentation/panes/settings_nav_row.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _url = 'https://home.example.test:8123';

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async =>
      const HaConnectionConfig(baseUrl: _url, token: 'synthetic-token');

  void replace() => state = const AsyncData(
    HaConnectionConfig(
      baseUrl: 'https://replacement.example.test:8123',
      token: 'replacement-token',
    ),
  );
}

class _NoDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async {}
}

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  _Connection? connection,
  HealthMonitor? monitor,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionConfigProvider.overrideWith(
          connection == null ? _Connection.new : () => connection,
        ),
        haDiscoveryFactoryProvider.overrideWithValue(_NoDiscovery.new),
        if (monitor != null) healthMonitorProvider.overrideWithValue(monitor),
        healthClockProvider.overrideWith(
          (ref) => Stream.value(DateTime(2026, 9, 20, 12)),
        ),
      ],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const ConnectionPane(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('connection separates saved, reachable, and verified evidence', (
    tester,
  ) async {
    final now = DateTime(2026, 9, 20, 12);
    final monitor = HealthMonitor(now: () => now);
    addTearDown(monitor.dispose);
    await _mount(tester, language: 'en', width: 600, monitor: monitor);

    expect(find.text('Saved connection'), findsOneWidget);
    expect(find.text('Not yet verified'), findsOneWidget);
    expect(find.text('Data read successfully'), findsNothing);

    final session = monitor.bind(IntegrationId.ha, configured: true);
    session.contact();
    await tester.pumpAndSettle();
    expect(
      find.text('Server responded; data not yet verified'),
      findsOneWidget,
    );

    session.readSucceeded();
    await tester.pumpAndSettle();
    expect(find.text('Data read successfully'), findsOneWidget);
  });

  testWidgets('captured connection action cannot open replaced HA config', (
    tester,
  ) async {
    final connection = _Connection();
    await _mount(tester, language: 'en', width: 600, connection: connection);
    final open = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('connection-home-assistant-action')),
        )
        .onPressed!;

    connection.replace();
    await tester.pumpAndSettle();
    open();
    await tester.pumpAndSettle();

    expect(find.byType(ConnectScreen), findsNothing);
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language connection action is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _mount(tester, language: language, width: width);

          expect(find.byType(SettingsPaneScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(find.byType(SettingsActionTile), findsOneWidget);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('connection-settings-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final action = find.byKey(
            const ValueKey('connection-home-assistant-action'),
          );
          expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
          Focus.of(
            tester.element(
              find.descendant(of: action, matching: find.byType(Text)).first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(ConnectScreen), findsOneWidget);
          expect(
            tester.widget<ConnectScreen>(find.byType(ConnectScreen)).initialUrl,
            _url,
          );
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}
