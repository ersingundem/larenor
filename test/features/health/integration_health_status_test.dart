import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/navigation/presentation/system_screen.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/navigation/providers/service_connection_providers.dart';
import 'package:larenor/features/settings/presentation/manage_integrations_screen.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/network/transport_observation.dart';
import 'package:larenor/shared/widgets/integration_health_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 9, 5, 11, 30);

class _Jellyfin extends JellyfinConnection {
  @override
  Future<JellyfinConfig?> build() async => const JellyfinConfig(
    baseUrl: 'https://private.invalid',
    userId: 'private-user',
    accessToken: 'private-token',
    deviceId: 'private-device',
  );

  void replaceAccount() => state = const AsyncData(
    JellyfinConfig(
      baseUrl: 'https://another-private.invalid',
      userId: 'another-user',
      accessToken: 'another-token',
      deviceId: 'same-device',
    ),
  );
}

class _HomeAssistant extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'http://ha-private.invalid',
    token: 'private-ha-token',
  );
}

Future<void> _show(
  WidgetTester tester,
  ProviderContainer container, {
  Widget page = const IntegrationHealthStatus(
    id: IntegrationId.jellyfin,
    configured: true,
  ),
  bool wrapPage = true,
  Locale locale = const Locale('en'),
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(500, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CupertinoApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: wrapPage
            ? CupertinoPageScaffold(
                child: Center(child: SizedBox(width: 300, child: page)),
              )
            : page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ProviderContainer _container(HealthMonitor monitor, {Stream<DateTime>? clock}) {
  final container = ProviderContainer(
    overrides: [
      healthMonitorProvider.overrideWithValue(monitor),
      healthClockProvider.overrideWith((ref) => clock ?? Stream.value(_now)),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(monitor.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'enabled_services_migrated': true});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'saved credentials with no observed session never claim connectivity',
    (tester) async {
      final monitor = HealthMonitor(now: () => _now);
      final container = _container(monitor);
      await _show(tester, container);
      expect(find.text('Saved connection'), findsOneWidget);
      expect(find.text('Not yet verified'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('Data read successfully'), findsNothing);
      expect(find.textContaining('Last successful read:'), findsNothing);
      expect(monitor.snapshot, isEmpty);
      expect(container.exists(jellyfinClientProvider), isFalse);
    },
  );

  testWidgets('an accepted HTTP write is contact, not a successful data read', (
    tester,
  ) async {
    final monitor = HealthMonitor(now: () => _now);
    final session = monitor.bind(IntegrationId.jellyfin, configured: true);
    final container = _container(monitor);
    await _show(tester, container);
    session.observeTransport(
      const TransportObservation(
        kind: TransportObservationKind.response,
        isRead: false,
        statusCode: 200,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Server responded; data not yet verified'),
      findsOneWidget,
    );
    expect(find.text('Data read successfully'), findsNothing);
    expect(find.textContaining('Last successful read:'), findsNothing);
  });

  testWidgets(
    'read evidence ages without any new network response or entity timestamp',
    (tester) async {
      final clock = StreamController<DateTime>.broadcast();
      addTearDown(clock.close);
      final monitor = HealthMonitor(now: () => _now);
      monitor.bind(IntegrationId.jellyfin, configured: true).readSucceeded();
      final container = _container(monitor, clock: clock.stream);
      await _show(tester, container);
      clock.add(_now);
      await tester.pumpAndSettle();
      expect(find.text('Data read successfully'), findsOneWidget);
      final lastRead =
          'Last successful read: ${DateFormat.yMd('en').add_Hm().format(_now.toLocal())}';
      expect(find.text(lastRead), findsOneWidget);
      clock.add(_now.add(const Duration(minutes: 3)));
      await tester.pumpAndSettle();
      expect(find.text('Last read is out of date'), findsOneWidget);
      expect(find.text(lastRead), findsOneWidget);
      expect(container.exists(jellyfinClientProvider), isFalse);
    },
  );

  for (final entry in {
    HealthFailure.authentication: 'Sign-in required',
    HealthFailure.permission: 'Permission required',
    HealthFailure.transport: 'Unable to reach service',
    HealthFailure.timeout: 'Unable to reach service',
    HealthFailure.server: 'Could not read service data',
    HealthFailure.invalidResponse: 'Could not read service data',
  }.entries) {
    testWidgets(
      '${entry.key.name} overrides an earlier successful read without erasing its timestamp',
      (tester) async {
        final monitor = HealthMonitor(now: () => _now);
        final session = monitor.bind(IntegrationId.jellyfin, configured: true)
          ..readSucceeded();
        final container = _container(monitor);
        await _show(tester, container);
        session.failed(entry.key);
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text('Data read successfully'), findsNothing);
        expect(find.textContaining('Last successful read:'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('connecting and retrying are distinct from a verified read', (
    tester,
  ) async {
    final monitor = HealthMonitor(now: () => _now);
    final session = monitor.bind(IntegrationId.jellyfin, configured: true)
      ..connecting();
    final container = _container(monitor);
    await _show(tester, container);
    expect(find.text('Connecting…'), findsOneWidget);
    session.retrying(2);
    await tester.pumpAndSettle();
    expect(find.text('Retrying connection'), findsOneWidget);
    expect(find.text('Data read successfully'), findsNothing);
    expect(find.textContaining('Last successful read:'), findsNothing);
  });

  testWidgets('removing saved configuration hides all old session evidence', (
    tester,
  ) async {
    final monitor = HealthMonitor(now: () => _now);
    monitor.bind(IntegrationId.jellyfin, configured: true).readSucceeded();
    final container = _container(monitor);
    await _show(
      tester,
      container,
      page: const IntegrationHealthStatus(
        id: IntegrationId.jellyfin,
        configured: false,
      ),
    );
    expect(find.text('No saved connection'), findsOneWidget);
    expect(find.text('Data read successfully'), findsNothing);
    expect(find.textContaining('Last successful read:'), findsNothing);
  });

  testWidgets(
    'replacing a bound account drops prior read and failure evidence',
    (tester) async {
      final monitor = HealthMonitor(now: () => _now);
      final old = monitor.bind(IntegrationId.jellyfin, configured: true)
        ..readSucceeded();
      final container = _container(monitor);
      await _show(tester, container);
      monitor.bind(IntegrationId.jellyfin, configured: true);
      old.failed(HealthFailure.authentication);
      old.readSucceeded();
      await tester.pumpAndSettle();
      expect(find.text('Saved connection'), findsOneWidget);
      expect(find.text('Not yet verified'), findsOneWidget);
      expect(find.text('Sign-in required'), findsNothing);
      expect(find.textContaining('Last successful read:'), findsNothing);
    },
  );

  testWidgets('Turkish health messages and large text fit a narrow card', (
    tester,
  ) async {
    final monitor = HealthMonitor(now: () => _now);
    monitor.bind(IntegrationId.jellyfin, configured: true)
      ..readSucceeded()
      ..failed(HealthFailure.authentication);
    final container = _container(monitor);
    await _show(tester, container, locale: const Locale('tr'), textScale: 2);
    expect(find.text('Yeniden giriş gerekli'), findsOneWidget);
    expect(find.textContaining('Son başarılı okuma:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saved account replacement clears former health before any new client starts',
    (tester) async {
      final monitor = HealthMonitor(now: () => _now);
      final connection = _Jellyfin();
      final container = ProviderContainer(
        overrides: [
          jellyfinConnectionProvider.overrideWith(() => connection),
          healthMonitorProvider.overrideWithValue(monitor),
          healthClockProvider.overrideWith((ref) => Stream.value(_now)),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(monitor.dispose);
      await _show(
        tester,
        container,
        page: const SavedServiceHealthStatus(service: AppService.jellyfin),
      );
      final oldConfig = container.read(jellyfinConnectionProvider).value!;
      final oldSession = monitor.bind(
        IntegrationId.jellyfin,
        configured: true,
        configurationIdentity: oldConfig,
      )..readSucceeded();
      await tester.pumpAndSettle();
      expect(find.text('Data read successfully'), findsOneWidget);
      connection.replaceAccount();
      await tester.pumpAndSettle();
      oldSession.failed(HealthFailure.authentication);
      oldSession.readSucceeded();
      await tester.pumpAndSettle();
      expect(find.text('Saved connection'), findsOneWidget);
      expect(find.text('Not yet verified'), findsOneWidget);
      expect(find.textContaining('Last successful read:'), findsNothing);
      expect(find.text('Sign-in required'), findsNothing);
      expect(container.exists(jellyfinClientProvider), isFalse);
    },
  );

  testWidgets(
    'System Home Assistant card reads configuration and evidence without opening REST or WebSocket clients',
    (tester) async {
      final monitor = HealthMonitor(now: () => _now);
      final container = ProviderContainer(
        overrides: [
          connectionConfigProvider.overrideWith(_HomeAssistant.new),
          healthMonitorProvider.overrideWithValue(monitor),
          healthClockProvider.overrideWith((ref) => Stream.value(_now)),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(monitor.dispose);
      await _show(
        tester,
        container,
        page: const SystemScreen(),
        wrapPage: false,
      );
      final card = find.byKey(const ValueKey('system-home-assistant'));
      expect(
        find.descendant(of: card, matching: find.text('Saved connection')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Not yet verified')),
        findsOneWidget,
      );
      expect(find.text('No optional services configured.'), findsOneWidget);
      expect(container.exists(haRestClientProvider), isFalse);
      expect(container.exists(haWebSocketClientProvider), isFalse);
      monitor.bind(IntegrationId.ha, configured: true).readSucceeded();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: card,
          matching: find.text('Data read successfully'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.textContaining('Last successful read:'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private-ha-token'), findsNothing);
      expect(find.textContaining('ha-private.invalid'), findsNothing);
      expect(container.exists(haRestClientProvider), isFalse);
      expect(container.exists(haWebSocketClientProvider), isFalse);
    },
  );

  testWidgets(
    'Manage Integrations shares passive health and never labels saved credentials Connected',
    (tester) async {
      final monitor = HealthMonitor(now: () => _now);
      final container = ProviderContainer(
        overrides: [
          jellyfinConnectionProvider.overrideWith(_Jellyfin.new),
          healthMonitorProvider.overrideWithValue(monitor),
          healthClockProvider.overrideWith((ref) => Stream.value(_now)),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(monitor.dispose);
      await _show(
        tester,
        container,
        page: const ManageIntegrationsScreen(),
        wrapPage: false,
      );
      expect(find.text('Saved connection'), findsOneWidget);
      expect(find.text('Not yet verified'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(container.exists(jellyfinClientProvider), isFalse);
      expect(
        container
            .read(savedServiceConnectionProvider(AppService.jellyfin))
            .value,
        isTrue,
      );
      final session = monitor.bind(IntegrationId.jellyfin, configured: true)
        ..readSucceeded();
      await tester.pumpAndSettle();
      expect(find.text('Data read successfully'), findsOneWidget);
      session.failed(HealthFailure.permission);
      await tester.pumpAndSettle();
      expect(find.text('Permission required'), findsOneWidget);
      expect(find.textContaining('private-'), findsNothing);
      expect(find.textContaining('private.invalid'), findsNothing);
      expect(container.exists(jellyfinClientProvider), isFalse);
    },
  );
}
