// Synthesize retained account state to check that UI never shows old data.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/keenetic_tile.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_metric_detail_screen.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_widget_picker_screen.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/keenetic/providers/keenetic_telemetry_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'keenetic_telemetry_test.dart' show fixtureConfig, telemetryResponse;

const _tile = TileConfig(
  id: 'router-card',
  type: TileType.keenetic,
  x: 0,
  y: 0,
  width: 2,
  height: 2,
);
const _inventoryRequest = KeeneticMetricRequest(KeeneticMetricKind.interfaces);

class _Connection extends KeeneticConnection {
  @override
  Future<KeeneticConfig?> build() async => fixtureConfig;
  void loading() => state = const AsyncLoading<KeeneticConfig?>()
      .copyWithPrevious(const AsyncData(fixtureConfig));
  void change() => state = const AsyncData(
    KeeneticConfig(
      baseUrl: 'http://other-router.test',
      username: 'other',
      password: 'other-fixture',
    ),
  );
}

class _Harness {
  final connection = _Connection();
  final visible = ValueNotifier(true);
  final results = <TileConfig>[];
  int requests = 0, clients = 0, legacyReads = 0;
  late ProviderContainer container;
  StreamController<KeeneticTelemetrySnapshot>? inventory;
  Future<void> mount(
    WidgetTester tester, {
    bool picker = false,
    bool detail = false,
    Size size = const Size(800, 1000),
    double scale = 1,
    bool overrideInventory = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (overrideInventory) {
      inventory = StreamController<KeeneticTelemetrySnapshot>.broadcast();
    }
    container = ProviderContainer(
      overrides: [
        keeneticConnectionProvider.overrideWith(() => connection),
        keeneticClientFactoryProvider.overrideWithValue((config, health) {
          clients++;
          return KeeneticClient(
            config: config,
            healthSession: health,
            httpClient: MockClient((request) async {
              requests++;
              return telemetryResponse(request);
            }),
          );
        }),
        keeneticClientProvider.overrideWith((_) async {
          legacyReads++;
          throw StateError('legacy client must not start');
        }),
        keeneticAccessPointsProvider.overrideWith((_) async {
          legacyReads++;
          return [];
        }),
        if (overrideInventory)
          keeneticMetricProvider(_inventoryRequest)
              .overrideWith((_) => inventory!.stream),
      ],
    );
    addTearDown(() {
      container.dispose();
      visible.dispose();
      inventory?.close();
    });
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
          home: picker
              ? Builder(
                  builder: (context) => CupertinoPageScaffold(
                    child: Center(
                      child: CupertinoButton(
                        child: const Text('Open metric picker'),
                        onPressed: () async {
                          final result = await Navigator.push<TileConfig>(
                            context,
                            CupertinoPageRoute(
                              builder: (_) =>
                                  const KeeneticWidgetPickerScreen(),
                            ),
                          );
                          if (result != null) results.add(result);
                        },
                      ),
                    ),
                  ),
                )
              : ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (context, showing, _) => TickerMode(
                    enabled: showing,
                    child: detail
                        ? const KeeneticMetricDetailScreen(tile: _tile)
                        : const CupertinoPageScaffold(
                            child: Center(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 180,
                                      child: KeeneticTile(tile: _tile),
                                    ),
                                  ),
                                  Expanded(
                                    child: SizedBox(
                                      height: 180,
                                      child: KeeneticTile(tile: _tile),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (picker) {
      await tester.tap(find.text('Open metric picker'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump();
  }

  KeeneticTelemetrySnapshot sample({
    DateTime? at,
    KeeneticReadFailure? issue,
    bool paused = false,
    KeeneticReadFailure? connectionIssue,
  }) => KeeneticTelemetrySnapshot(
    accountGeneration: Object(),
    isPaused: paused,
    connectionIssue: connectionIssue,
    interfaces: KeeneticReading(
      value: [
        KeeneticInterface(
          id: 'wan',
          description: 'WAN interface',
          address: '192.0.2.10',
        ),
      ],
      readAt: at ?? DateTime.now(),
      issue: issue,
    ),
  );
  CupertinoButton addButton(WidgetTester tester) =>
      tester.widget<CupertinoButton>(
        find
            .ancestor(
              of: find.text('Add'),
              matching: find.byType(CupertinoButton),
            )
            .first,
      );
  Future<void> traffic(WidgetTester tester) async {
    await tester.tap(find.text('Network traffic'));
    await tester.pump();
  }

  Future<void> select(WidgetTester tester) async {
    final choice = find.text('WAN interface');
    await tester.scrollUntilVisible(
      choice,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(choice);
    await tester.pump();
  }
}

void _pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _resume(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets('static picker reads no router and saves a single local draft', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, picker: true);
    expect(h.requests, 0);
    expect(h.clients, 0);
    expect(h.legacyReads, 0);
    final callback = h.addButton(tester).onPressed!;
    callback();
    callback();
    await tester.pumpAndSettle();
    expect(h.results, hasLength(1));
    expect(h.results.single.keeneticMetric, KeeneticMetricKind.internetStatus);
    expect(h.results.single.keeneticInterfaceId, isNull);
    expect(h.requests, 0);
    await h.close(tester);
  });
  testWidgets(
    'two generic cards share one telemetry client and never start old AP providers',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(h.clients, 1);
      expect(h.requests, 2);
      expect(h.legacyReads, 0);
      expect(find.text('8%'), findsNWidgets(2));
      final count = h.requests;
      h.visible.value = false;
      await tester.pumpAndSettle();
      expect(h.container.exists(keeneticTelemetryControllerProvider), isFalse);
      await tester.pump(const Duration(minutes: 1));
      expect(h.requests, count);
      h.visible.value = true;
      await tester.pumpAndSettle();
      expect(h.clients, 2);
      expect(h.legacyReads, 0);
      await h.close(tester);
    },
  );
  testWidgets(
    'background releases cards demand, resume obtains a new visible snapshot',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final count = h.requests;
      _pause(tester);
      await tester.pumpAndSettle();
      expect(h.container.exists(keeneticTelemetryControllerProvider), isFalse);
      await tester.pump(const Duration(minutes: 1));
      expect(h.requests, count);
      _resume(tester);
      await tester.pumpAndSettle();
      expect(h.requests, greaterThan(count));
      expect(find.text('8%'), findsNWidgets(2));
      await h.close(tester);
    },
  );
  testWidgets(
    'retained account loading removes previous card readings immediately',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(find.text('8%'), findsNWidgets(2));
      h.connection.loading();
      await tester.pump();
      expect(find.text('8%'), findsNothing);
      expect(h.container.exists(keeneticTelemetryControllerProvider), isFalse);
      await h.close(tester);
    },
  );
  testWidgets(
    'traffic picker requires current inventory and double Add returns only one selection',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, picker: true, overrideInventory: true);
      await h.traffic(tester);
      expect(h.addButton(tester).onPressed, isNull);
      h.inventory!.add(h.sample());
      await tester.pumpAndSettle();
      await h.select(tester);
      final callback = h.addButton(tester).onPressed!;
      callback();
      callback();
      await tester.pumpAndSettle();
      expect(h.results, hasLength(1));
      expect(h.results.single.keeneticInterfaceId, 'wan');
      expect(h.results.single.keeneticMetric, KeeneticMetricKind.wanTraffic);
      await h.close(tester);
    },
  );
  for (final failure in [
    'age',
    'readError',
    'connectionError',
    'paused',
    'account',
    'loading',
    'background',
  ]) {
    testWidgets('traffic $failure rejects previously enabled Add callback', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester, picker: true, overrideInventory: true);
      await h.traffic(tester);
      h.inventory!.add(h.sample());
      await tester.pumpAndSettle();
      await h.select(tester);
      final callback = h.addButton(tester).onPressed!;
      switch (failure) {
        case 'age':
          h.inventory!.add(
            h.sample(at: DateTime.now().subtract(const Duration(minutes: 2))),
          );
        case 'readError':
          h.inventory!.add(h.sample(issue: KeeneticReadFailure.permission));
        case 'connectionError':
          h.inventory!.add(
            h.sample(connectionIssue: KeeneticReadFailure.transport),
          );
        case 'paused':
          h.inventory!.add(h.sample(paused: true));
        case 'account':
          h.connection.change();
        case 'loading':
          h.connection.loading();
        case 'background':
          _pause(tester);
      }
      await tester.pump();
      callback();
      await tester.pump();
      expect(h.results, isEmpty);
      if (failure == 'background') _resume(tester);
      await h.close(tester);
    });
  }
  for (final size in [const Size(320, 900), const Size(1440, 1100)]) {
    testWidgets(
      'metric cards, detail and static picker fit $size at text scale 2',
      (tester) async {
        final cards = _Harness();
        await cards.mount(tester, size: size, scale: 2);
        expect(tester.takeException(), isNull);
        await cards.close(tester);
        final detail = _Harness();
        await detail.mount(tester, detail: true, size: size, scale: 2);
        expect(find.text('8%'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await detail.close(tester);
        final picker = _Harness();
        await picker.mount(tester, picker: true, size: size, scale: 2);
        await tester.scrollUntilVisible(find.text('Network interfaces'), 200);
        expect(tester.takeException(), isNull);
        expect(picker.requests, 0);
        await picker.close(tester);
      },
    );
  }
}
