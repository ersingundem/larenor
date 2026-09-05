import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/weather_tile.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _tile = TileConfig(
  id: 'weather',
  type: TileType.weather,
  x: 0,
  y: 0,
  width: 2,
  height: 2,
  entityId: 'weather.home',
);
const _states = {
  'weather.home': HaEntity(
    entityId: 'weather.home',
    state: 'sunny',
    attributes: {
      'friendly_name': 'Home weather',
      'temperature': 17,
      'temperature_unit': '°C',
    },
  ),
  'weather.other': HaEntity(
    entityId: 'weather.other',
    state: 'rainy',
    attributes: {
      'friendly_name': 'Other weather',
      'temperature': 14,
      'temperature_unit': '°C',
    },
  ),
};
Object _response(String id, num temperature) => {
  'service_response': {
    id: {
      'forecast': [
        {
          'datetime': '2026-09-05T00:00:00+03:00',
          'condition': 'sunny',
          'temperature': temperature,
        },
      ],
    },
  },
};

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'http://weather.invalid',
    token: 'first',
  );
  void change() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://weather.invalid', token: 'second'),
  );
  void loading() => state = const AsyncLoading();
}

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => _states;
  void failure() {
    const failure = AsyncError<Map<String, HaEntity>>(
      'private-state-error',
      StackTrace.empty,
    );
    // ignore: invalid_use_of_internal_member
    state = failure.copyWithPrevious(const AsyncData(_states));
  }
}

class _Rest extends HaRestClient {
  _Rest(this.temperature)
    : super(baseUrl: 'http://weather.invalid', token: 'fixture');
  final num temperature;
  final requests = <String>[];
  Future<Object> Function(String)? handler;
  @override
  Future<dynamic> postJson(String path, [Map<String, dynamic>? body]) async {
    expectSync(path, '/api/services/weather/get_forecasts?return_response');
    expectSync(body?['type'], 'daily');
    final id = body!['entity_id'] as String;
    requests.add(id);
    return handler?.call(id) ?? _response(id, temperature);
  }
}

class _Harness {
  final connection = _Connection();
  final entities = _Entities();
  final first = _Rest(21);
  final second = _Rest(31);
  final visible = ValueNotifier(true);
  final tile = ValueNotifier(_tile);
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester, {
    bool duplicate = false,
    double scale = 1,
    double height = 320,
  }) async {
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionConfigProvider.overrideWith(() => connection),
        entitiesProvider.overrideWith(() => entities),
        haRestClientProvider.overrideWith((ref) {
          final account = ref.watch(connectionConfigProvider);
          return account.isLoading || account.hasError || account.value == null
              ? null
              : account.value!.token == 'first'
              ? first
              : second;
        }),
      ],
    );
    addTearDown(() {
      container.dispose();
      first.dispose();
      second.dispose();
      visible.dispose();
      tile.dispose();
    });
    final accountSubscription = container.listen(
      connectionConfigProvider,
      (_, _) {},
    );
    final statesSubscription = container.listen(entitiesProvider, (_, _) {});
    addTearDown(accountSubscription.close);
    addTearDown(statesSubscription.close);
    await container.read(connectionConfigProvider.future);
    await container.read(entitiesProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: CupertinoPageScaffold(
            child: Center(
              child: SizedBox(
                width: 280,
                height: height,
                child: ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (context, enabled, _) => TickerMode(
                    enabled: enabled,
                    child: ValueListenableBuilder(
                      valueListenable: tile,
                      builder: (context, current, _) => duplicate
                          ? Row(
                              children: [
                                Expanded(child: WeatherTile(tile: current)),
                                Expanded(child: WeatherTile(tile: current)),
                              ],
                            )
                          : WeatherTile(tile: current),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

void main() {
  test(
    'forecast parsing preserves calendar date and rejects malformed response',
    () {
      final days = parseWeatherForecast(
        _response('weather.home', 21),
        'weather.home',
      );
      expect(days.single.date, DateTime(2026, 9, 5));
      expect(
        () => parseWeatherForecast({
          'service_response': {
            'weather.home': {
              'forecast': [
                {'datetime': 'invalid', 'temperature': double.nan},
              ],
            },
          },
        }, 'weather.home'),
        throwsFormatException,
      );
      expect(
        () => parseWeatherForecast({}, 'weather.home'),
        throwsFormatException,
      );
    },
  );
  testWidgets('two visible cards share one forecast read', (tester) async {
    final h = _Harness();
    await h.mount(tester, duplicate: true);
    await tester.pumpAndSettle();
    expect(h.first.requests, ['weather.home']);
    expect(find.text('21°C'), findsNWidgets(2));
  });
  testWidgets('offstage card performs no read until visible', (tester) async {
    final h = _Harness();
    h.visible.value = false;
    await h.mount(tester);
    await tester.pumpAndSettle();
    expect(h.first.requests, isEmpty);
    expect(
      h.container.exists(weatherForecastProvider('weather.home')),
      isFalse,
    );
    h.visible.value = true;
    await tester.pumpAndSettle();
    expect(h.first.requests, ['weather.home']);
  });
  testWidgets('pending read survives hide and resume without overlap', (
    tester,
  ) async {
    final h = _Harness();
    final pending = Completer<Object>();
    h.first.handler = (_) => pending.future;
    await h.mount(tester);
    expect(h.first.requests, ['weather.home']);
    h.visible.value = false;
    await tester.pump();
    await tester.pump();
    h.visible.value = true;
    await tester.pump();
    await tester.pump();
    expect(h.first.requests, ['weather.home']);
    pending.complete(_response('weather.home', 21));
    await tester.pumpAndSettle();
    expect(find.text('21°C'), findsOneWidget);
  });
  testWidgets(
    'old account forecast completion never replaces new account data',
    (tester) async {
      final h = _Harness();
      final pending = Completer<Object>();
      h.first.handler = (_) => pending.future;
      await h.mount(tester);
      h.connection.change();
      await tester.pumpAndSettle();
      expect(h.container.read(connectionConfigProvider).value!.token, 'second');
      expect(
        identical(h.container.read(haRestClientProvider), h.second),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(h.second.requests, ['weather.home']);
      expect(
        h.container
            .read(weatherForecastProvider('weather.home'))
            .value
            ?.single
            .temperature,
        31,
        reason: h.container
            .read(weatherForecastProvider('weather.home'))
            .toString(),
      );
      expect(find.text('31°C'), findsOneWidget);
      pending.complete(_response('weather.home', 99));
      await tester.pumpAndSettle();
      expect(find.text('99°C'), findsNothing);
      expect(find.text('31°C'), findsOneWidget);
    },
  );
  testWidgets('changing entity cannot attach previous entity forecast', (
    tester,
  ) async {
    final h = _Harness();
    final pending = Completer<Object>();
    h.first.handler = (id) =>
        id == 'weather.home' ? pending.future : Future.value(_response(id, 41));
    await h.mount(tester);
    h.tile.value = _tile.copyWith(entityId: 'weather.other');
    await tester.pumpAndSettle();
    pending.complete(_response('weather.home', 99));
    await tester.pumpAndSettle();
    expect(find.text('41°C'), findsOneWidget);
    expect(find.text('99°C'), findsNothing);
    expect(find.text('Home weather'), findsNothing);
  });
  testWidgets('background hides weather and never initiates a new request', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await tester.pumpAndSettle();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(seconds: 20));
    expect(h.first.requests, ['weather.home']);
    expect(find.text('21°C'), findsNothing);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text('21°C'), findsOneWidget);
  });
  testWidgets('failure stays distinct from empty and retries only on tap', (
    tester,
  ) async {
    final h = _Harness();
    h.first.handler = (_) => Future.error(StateError('private-server-error'));
    await h.mount(tester);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(h.first.requests, hasLength(1));
    expect(find.textContaining('private-server'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    h.first.handler = (id) => Future.value(_response(id, 21));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(h.first.requests, hasLength(2));
    expect(find.text('21°C'), findsOneWidget);
  });
  testWidgets('old retry callback cannot read after account replacement', (
    tester,
  ) async {
    final h = _Harness();
    h.first.handler = (_) => Future.error(StateError('fixture failure'));
    await h.mount(tester);
    await tester.pumpAndSettle();
    final retry = tester
        .widget<CupertinoButton>(
          find.ancestor(
            of: find.text('Retry'),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;
    h.connection.change();
    await tester.pumpAndSettle();
    expect(h.second.requests, ['weather.home']);
    retry();
    await tester.pumpAndSettle();
    expect(h.second.requests, ['weather.home']);
  });
  testWidgets('loading account and retained failed states hide old weather', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await tester.pumpAndSettle();
    h.entities.failure();
    await tester.pumpAndSettle();
    expect(find.text('Home weather'), findsNothing);
    expect(find.text('21°C'), findsNothing);
    h.connection.loading();
    await tester.pumpAndSettle();
    expect(h.first.requests, hasLength(1));
  });
  testWidgets(
    'late completion after unmount is harmless and compact 2x card scrolls',
    (tester) async {
      final h = _Harness();
      final pending = Completer<Object>();
      h.first.handler = (_) => pending.future;
      await h.mount(tester, scale: 2, height: 120);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      pending.complete(_response('weather.home', 99));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
