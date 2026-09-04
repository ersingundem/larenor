import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

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
  }) async {
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
    if (narrow) {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionConfigProvider.overrideWith(_Config.new),
          entitiesProvider.overrideWith(_Entities.new),
          haRestClientProvider.overrideWithValue(rest),
          haWebSocketClientProvider.overrideWithValue(socket),
          healthMonitorProvider.overrideWithValue(monitor),
          if (!setup)
            doorStationsProvider.overrideWith((ref) async => [_station]),
          haActionsProvider.overrideWith(
            (ref) async => const [
              HaAction(domain: 'button', service: 'press', metadata: {}),
            ],
          ),
        ],
        child: CupertinoApp(
          locale: const Locale('tr'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
            child: child!,
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

  testWidgets('backgrounding invalidates a still-visible door confirmation', (
    tester,
  ) async {
    final requests = await mount(tester);
    await tester.tap(find.text('Kapıyı aç'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Kapıyı aç'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(
      find.text(
        'Diafon hazır değil. Güncel görüşmeyi, bağlantıyı ve kurulumu kontrol et.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

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
}
