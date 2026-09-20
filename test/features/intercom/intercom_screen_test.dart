import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/domain/ha_action.dart';
import 'package:larenor/features/ha_tools/presentation/ha_actions_screen.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/intercom/domain/door_station.dart';
import 'package:larenor/features/intercom/presentation/intercom_screen.dart';
import 'package:larenor/features/intercom/presentation/intercom_settings_screen.dart';
import 'package:larenor/features/intercom/providers/intercom_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/direct_home_routines_test.dart' show routinesHome;

const _config = HaConnectionConfig(baseUrl: 'http://ha.test', token: 'fixture');
const _station = DoorStation(
  id: 'entrance',
  name: 'Bina girişi',
  serverUrl: 'http://ha.test',
  unlockEntityId: 'button.release',
  callActiveEntityId: 'binary_sensor.call',
  chimeEntityId: 'binary_sensor.chime',
  unlockEnabled: true,
);

class _Config extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => _config;
}

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => const {
    'button.release': HaEntity(entityId: 'button.release', state: 'unknown'),
    'binary_sensor.call': HaEntity(entityId: 'binary_sensor.call', state: 'on'),
  };
}

class _Socket extends HaWebSocketClient {
  _Socket() : super(baseUrl: _config.baseUrl, token: _config.token);
  @override
  Stream<HaConnectionStatus> get status =>
      Stream.value(HaConnectionStatus.connected);
}

void main() {
  Future<List<http.Request>> mount(
    WidgetTester tester, {
    bool fresh = true,
    bool setup = false,
    bool narrow = false,
    Size? size,
    double? scale,
    Locale locale = const Locale('tr'),
    AppInteractionController? interaction,
    HomeSessionController? home,
    List<DoorStation> Function()? stationValues,
  }) async {
    final scope = interaction ?? AppInteractionController();
    if (interaction == null) addTearDown(scope.dispose);
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    final rest = HaRestClient(
      baseUrl: _config.baseUrl,
      token: _config.token,
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('[]', 200);
      }),
    );
    final socket = _Socket();
    addTearDown(rest.dispose);
    addTearDown(socket.dispose);
    final monitor = HealthMonitor();
    addTearDown(monitor.dispose);
    final session = monitor.bind(
      IntegrationId.ha,
      configured: true,
      configurationIdentity: _config,
    );
    if (fresh) {
      session.liveConnected();
      session.readSucceeded(synchronizesLiveSnapshot: true);
    }
    if (narrow || size != null) {
      tester.view.physicalSize = size ?? const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (home != null)
            homeSessionControllerProvider.overrideWithValue(home),
          connectionConfigProvider.overrideWith(_Config.new),
          entitiesProvider.overrideWith(_Entities.new),
          haRestClientProvider.overrideWithValue(rest),
          haWebSocketClientProvider.overrideWithValue(socket),
          healthMonitorProvider.overrideWithValue(monitor),
          if (stationValues != null)
            doorStationsProvider.overrideWith((ref) async => stationValues())
          else if (!setup)
            doorStationsProvider.overrideWith((ref) async => [_station]),
          haActionsProvider.overrideWith(
            (ref) async => const [
              HaAction(domain: 'button', service: 'press', metadata: {}),
            ],
          ),
        ],
        child: CupertinoApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale ?? (narrow ? 2 : 1)),
            ),
            child: AppInteractionScope(controller: scope, child: child!),
          ),
          home: setup ? const IntercomSettingsScreen() : const IntercomScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return requests;
  }

  testWidgets(
    'door request needs a named confirmation and cancellation sends nothing',
    (tester) async {
      final requests = await mount(tester);
      expect(requests, isEmpty);
      await tester.tap(find.text('Kapıyı aç'));
      await tester.pumpAndSettle();
      expect(find.text('Bina girişi kapısı açılsın mı?'), findsOneWidget);
      expect(requests, isEmpty);
      await tester.tap(find.text('İptal'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'confirmed button request is sent once and is only server acceptance',
    (tester) async {
      final requests = await mount(tester);
      await tester.tap(find.text('Kapıyı aç'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Kapıyı aç'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/services/button/press');
      expect(find.text('Home Assistant isteği kabul etti'), findsOneWidget);
      expect(find.text('Home Assistant istenen durumu bildirdi'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('backgrounding closes the owned door confirmation', (
    tester,
  ) async {
    final requests = await mount(tester);
    await tester.tap(find.text('Kapıyı aç'));
    await tester.pumpAndSettle();
    final old = tester
        .widget<CupertinoDialogAction>(
          find.widgetWithText(CupertinoDialogAction, 'Kapıyı aç'),
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
    }
    await tester.pump();
    old();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'idle cancels door confirmation before its TTL and wake never revives it',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      final requests = await mount(tester, interaction: scope);
      await tester.tap(find.text('Kapıyı aç'));
      await tester.pumpAndSettle();
      final old = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Kapıyı aç'),
          )
          .onPressed!;
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pumpAndSettle();
      old();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('stale state cannot release and unknown chime is not idle', (
    tester,
  ) async {
    final requests = await mount(tester, fresh: false, narrow: true);
    expect(find.text('Zil durumu alınamıyor'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoButton>(
            find.widgetWithText(CupertinoButton, 'Kapıyı aç'),
          )
          .onPressed,
      isNull,
    );
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'new station configuration saves disabled without device actions',
    (tester) async {
      final requests = await mount(tester, setup: true, narrow: true);
      await tester.tap(find.text('Diafon ekle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField), 'Giriş');
      await tester.scrollUntilVisible(
        find.text('Kaydet'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      final raw = (await SharedPreferences.getInstance()).getString(
        DoorStation.storageKey,
      );
      expect(raw, contains('Giriş'));
      expect(raw, contains('"unlockEnabled":false'));
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'intercom setup uses the shared tablet surface $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(
              tester,
              setup: true,
              size: Size(width, 1100),
              scale: 2,
              locale: Locale(language),
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(IntercomSettingsScreen)),
            );

            expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
            expect(find.byType(SettingsActionTile), findsAtLeastNWidgets(1));
            final heading = find.byKey(
              const ValueKey('intercom-stations-heading'),
            );
            final headingNode = tester.getSemantics(heading);
            expect(headingNode.label, l10n.intercomTitle);
            expect(headingNode.flagsCollection.isHeader, isTrue);
            expect(headingNode.flagsCollection.isButton, isFalse);

            final add = find.byKey(const ValueKey('intercom-add-action'));
            final addNode = tester.getSemantics(add);
            expect(addNode.label, l10n.intercomAdd);
            expect(addNode.flagsCollection.isButton, isTrue);
            expect(addNode.rect.width, greaterThanOrEqualTo(48));
            expect(addNode.rect.height, greaterThanOrEqualTo(48));

            final label = find.descendant(
              of: add,
              matching: find.text(l10n.intercomAdd),
            );
            Focus.of(tester.element(label)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.text(l10n.intercomSetup), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
  testWidgets('captured add action cannot open after lifecycle round trip', (
    tester,
  ) async {
    await mount(tester, setup: true);
    final old = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('intercom-add-action')),
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
    }
    await tester.pump();
    old();
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('removed station rejects retained edit callback', (tester) async {
    var stations = const [_station];
    await mount(tester, setup: true, stationValues: () => stations);
    final old = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('intercom-station-entrance')),
        )
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(IntercomSettingsScreen)),
    );
    stations = const [];
    container.invalidate(doorStationsProvider);
    await tester.pumpAndSettle();

    old();
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoTextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'old station editor Save cannot acquire new Direct store after source return',
    (tester) async {
      final (_, home) = await routinesHome('direct');
      final requests = await mount(tester, setup: true, home: home);
      final add = find.byIcon(CupertinoIcons.add_circled);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(CupertinoTextField).first,
        'Private entry',
      );
      final save = tester
          .widget<CupertinoButton>(
            find.widgetWithText(CupertinoButton, 'Kaydet'),
          )
          .onPressed!;
      await home.choose(HomeSource.verifiedCore);
      await home.choose(HomeSource.directLocal);
      save();
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.get(DoorStation.storageKey), isNull);
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
