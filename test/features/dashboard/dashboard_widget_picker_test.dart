import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_widget_picker_screen.dart';
import 'package:larenor/features/dashboard/presentation/home_dashboard_screen.dart';
import 'package:larenor/features/dashboard/presentation/tiles/camera_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/history_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/climate_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/media_player_tile.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _config = HaConnectionConfig(
  baseUrl: 'http://home.invalid:8123',
  token: 'fixture',
);
final _fixtures = <String, HaEntity>{
  for (final entity in const [
    HaEntity(
      entityId: 'light.lamp',
      state: 'on',
      attributes: {'friendly_name': 'Lamp'},
    ),
    HaEntity(
      entityId: 'camera.front',
      state: 'idle',
      attributes: {'friendly_name': 'Front camera'},
    ),
    HaEntity(
      entityId: 'climate.room',
      state: 'heat',
      attributes: {'friendly_name': 'Room climate'},
    ),
    HaEntity(
      entityId: 'media_player.tv',
      state: 'playing',
      attributes: {'friendly_name': 'TV'},
    ),
    HaEntity(
      entityId: 'scene.evening',
      state: 'scening',
      attributes: {'friendly_name': 'Evening'},
    ),
    HaEntity(
      entityId: 'weather.home',
      state: 'sunny',
      attributes: {'friendly_name': 'Home weather'},
    ),
    HaEntity(
      entityId: 'sensor.temperature',
      state: '22.5',
      attributes: {'friendly_name': 'Temperature'},
    ),
    HaEntity(
      entityId: 'sensor.text',
      state: 'clear',
      attributes: {'friendly_name': 'Text'},
    ),
    HaEntity(entityId: 'camera.hidden', state: 'idle'),
    HaEntity(entityId: 'camera.disabled', state: 'idle'),
  ])
    entity.entityId: entity,
};

class _Connection extends ConnectionConfig {
  HaConnectionConfig? initial = _config;
  @override
  Future<HaConnectionConfig?> build() async => initial;
  void change() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://other.invalid', token: 'new'),
  );
  void sameServerOtherAccount() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://home.invalid:8123', token: 'new'),
  );
  void loading() => state = const AsyncLoading();
}

class _Entities extends Entities {
  Map<String, HaEntity> values = _fixtures;
  bool failed = false;
  @override
  Future<Map<String, HaEntity>> build() async {
    if (failed) throw StateError('private-server-details');
    return values;
  }

  void staleFailure() => state = const AsyncError<Map<String, HaEntity>>(
    'private',
    StackTrace.empty,
    // ignore: invalid_use_of_internal_member
  ).copyWithPrevious(AsyncData(values));
}

class _Repository extends DashboardRepository {
  DashboardLayout saved = const DashboardLayout();
  int writes = 0;
  bool fail = false;
  @override
  Future<DashboardLayout> load() async => saved;
  @override
  Future<void> save(
    DashboardLayout layout, {
    bool Function()? isCurrent,
  }) async {
    if (fail) throw StateError('private-storage-details');
    if (isCurrent?.call() == false) return;
    saved = layout;
    writes++;
  }
}

class _Harness {
  final connection = _Connection();
  final entities = _Entities();
  final repository = _Repository();
  final results = <TileConfig>[];
  late ProviderContainer container;
  bool registryFailed = false;
  int registryReads = 0;
  Future<void> mount(
    WidgetTester tester, {
    TileType? initialType,
    bool home = false,
    Size size = const Size(800, 1100),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionConfigProvider.overrideWith(() => connection),
        entitiesProvider.overrideWith(() => entities),
        dashboardRepositoryProvider.overrideWithValue(repository),
        dashboardWidgetRegistryProvider.overrideWith((ref) async {
          registryReads++;
          if (registryFailed) throw StateError('private-registry-detail');
          return const [
            HaRegistryEntry(entityId: 'camera.hidden', hiddenBy: 'user'),
            HaRegistryEntry(
              entityId: 'camera.disabled',
              disabledBy: 'integration',
            ),
          ];
        }),
        enabledServicesProvider.overrideWithBuild((ref, notifier) async => {}),
        haConnectionStatusProvider.overrideWith(
          (ref) => Stream.value(HaConnectionStatus.connected),
        ),
      ],
    );
    addTearDown(container.dispose);
    if (home) await container.read(connectionConfigProvider.future);
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
          home: home
              ? const HomeDashboardScreen()
              : Builder(
                  builder: (context) => CupertinoPageScaffold(
                    child: Center(
                      child: CupertinoButton(
                        child: const Text('Open picker'),
                        onPressed: () async {
                          final result = await Navigator.push<TileConfig>(
                            context,
                            CupertinoPageRoute(
                              builder: (_) => DashboardWidgetPickerScreen(
                                initialType: initialType,
                              ),
                            ),
                          );
                          if (result != null) results.add(result);
                        },
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!home) {
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
    }
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

void main() {
  test('website parser rejects credentials, ambiguous syntax and controls', () {
    for (final url in [
      'https://user:password@example.com',
      'https://@example.com',
      'https://example.com\\path',
      'https://example.com/%0afoo',
      'https://example.com/%5cfoo',
      'https://example.com\n',
      'https://example.com:99999',
      'javascript:alert(1)',
      '//example.com',
      'https://',
    ]) {
      expect(dashboardWebsiteUrl(url), isNull, reason: url);
    }
    expect(
      dashboardWebsiteUrl('https://example.com/path?q=a%20b#part'),
      'https://example.com/path?q=a%20b#part',
    );
    expect(dashboardWebsiteUrl('http://192.0.2.1:8123/page'), isNotNull);
  });
  test('history compatibility excludes nonnumeric and timestamp readings', () {
    expect(
      dashboardWidgetSupports(TileType.history, _fixtures['sensor.text']!),
      isFalse,
    );
    expect(
      dashboardWidgetSupports(
        TileType.history,
        const HaEntity(entityId: 'sensor.bad', state: 'NaN'),
      ),
      isFalse,
    );
    expect(
      dashboardWidgetSupports(
        TileType.history,
        const HaEntity(
          entityId: 'sensor.date',
          state: '123',
          attributes: {'device_class': 'timestamp'},
        ),
      ),
      isFalse,
    );
    expect(
      dashboardWidgetSupports(
        TileType.history,
        const HaEntity(
          entityId: 'sensor.wait',
          state: 'unavailable',
          attributes: {'state_class': 'measurement'},
        ),
      ),
      isTrue,
    );
  });
  testWidgets(
    'static gallery creates no HA readers, service widgets or controls',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(h.registryReads, 0);
      expect(h.container.exists(entitiesProvider), isFalse);
      expect(h.container.exists(haAdminClientProvider), isFalse);
      expect(h.container.exists(haRestClientProvider), isFalse);
      expect(find.byType(CameraTile), findsNothing);
      expect(find.byType(HistoryTile), findsNothing);
      expect(find.byType(ClimateTile), findsNothing);
      expect(find.byType(MediaPlayerTile), findsNothing);
      expect(find.byKey(const ValueKey('widget-kind-camera')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('widget-kind-keenetic')),
        250,
      );
      expect(
        find.byKey(const ValueKey('widget-kind-keenetic')),
        findsOneWidget,
      );
    },
  );
  for (final (kind, id) in [
    (TileType.entity, 'light.lamp'),
    (TileType.camera, 'camera.front'),
    (TileType.climate, 'climate.room'),
    (TileType.mediaPlayer, 'media_player.tv'),
    (TileType.scene, 'scene.evening'),
    (TileType.weather, 'weather.home'),
    (TileType.history, 'sensor.temperature'),
  ]) {
    testWidgets('${kind.name} creates compatible bounded draft only once', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester, initialType: kind);
      final finder = find.byKey(ValueKey('widget-entity-$id'));
      await tester.ensureVisible(finder);
      final button = tester.widget<CupertinoButton>(finder);
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(h.results, hasLength(1));
      final draft = h.results.single;
      expect(draft.type, kind);
      expect(draft.entityId, id);
      expect(draft.width, kind == TileType.entity ? 1 : 2);
      expect(draft.height, kind == TileType.entity ? 1 : 2);
      expect(h.repository.writes, 0);
      expect(
        () => validateDashboardLayoutJson(
          DashboardLayout(tiles: [draft]).toJson(),
        ),
        returnsNormally,
      );
      expect(h.container.exists(haRestClientProvider), isFalse);
    });
  }
  testWidgets(
    'camera filter excludes other domains and hidden registry entries',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, initialType: TileType.camera);
      expect(
        find.byKey(const ValueKey('widget-entity-camera.front')),
        findsOneWidget,
      );
      for (final id in [
        'climate.room',
        'camera.hidden',
        'camera.disabled',
        'light.lamp',
      ]) {
        expect(find.byKey(ValueKey('widget-entity-$id')), findsNothing);
      }
    },
  );
  testWidgets('registry denial is partial evidence, not false empty', (
    tester,
  ) async {
    final h = _Harness()..registryFailed = true;
    await h.mount(tester, initialType: TileType.camera);
    expect(
      find.textContaining('registry metadata could not be read'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('widget-entity-camera.front')),
      findsOneWidget,
    );
    expect(find.textContaining('private-registry'), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(h.registryReads, 1);
  });
  testWidgets('missing connection, read failure and known empty are distinct', (
    tester,
  ) async {
    final h = _Harness();
    h.connection.initial = null;
    await h.mount(tester, initialType: TileType.camera);
    expect(h.registryReads, 0);
    expect(h.container.exists(entitiesProvider), isFalse);
    expect(
      find.textContaining('Not connected', findRichText: true),
      findsOneWidget,
    );
  });
  testWidgets('known empty state list is an empty result, not an error', (
    tester,
  ) async {
    final h = _Harness();
    h.entities.values = {};
    await h.mount(tester, initialType: TileType.camera);
    expect(
      find.text('No compatible devices are available for this card.'),
      findsOneWidget,
    );
    expect(find.textContaining('could not be read'), findsNothing);
  });
  testWidgets('cancelled popup callback cannot open a picker or pop Home', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, home: true);
    await _tap(tester, find.byIcon(CupertinoIcons.add_circled).first);
    final callback = tester
        .widget<CupertinoActionSheetAction>(
          find.ancestor(
            of: find.text('Add Widget'),
            matching: find.byType(CupertinoActionSheetAction),
          ),
        )
        .onPressed;
    await _tap(tester, find.text('Cancel'));
    callback();
    await tester.pumpAndSettle();
    expect(find.byType(HomeDashboardScreen), findsOneWidget);
    expect(find.byType(DashboardWidgetPickerScreen), findsNothing);
    expect(h.repository.writes, 0);
  });
  testWidgets('read error never renders retained old entities as selections', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, initialType: TileType.camera);
    h.entities.staleFailure();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Current device states could not be read'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('widget-entity-camera.front')),
      findsNothing,
    );
    expect(find.textContaining('private'), findsNothing);
  });
  testWidgets('known empty and no search match have different messages', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, initialType: TileType.camera);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'zzz');
    await tester.pumpAndSettle();
    expect(
      find.text('No matching devices. Try another search.'),
      findsOneWidget,
    );
  });
  for (final change in [
    'account',
    'sameServerAccount',
    'background',
    'loading',
  ]) {
    testWidgets(
      '$change expires picker and retained callback cannot return draft',
      (tester) async {
        final h = _Harness();
        await h.mount(tester, initialType: TileType.camera);
        final callback = tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('widget-entity-camera.front')),
            )
            .onPressed!;
        switch (change) {
          case 'account':
            h.connection.change();
          case 'sameServerAccount':
            h.connection.sameServerOtherAccount();
          case 'loading':
            h.connection.loading();
          case 'background':
            await _resume(tester);
        }
        await tester.pumpAndSettle();
        callback();
        await tester.pumpAndSettle();
        expect(h.results, isEmpty);
        expect(find.textContaining('Close this picker'), findsOneWidget);
      },
    );
  }
  testWidgets('website input validates without creating a webview', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, initialType: TileType.webview);
    await tester.enterText(
      find.byKey(const ValueKey('widget-website-url')),
      'https://user:secret@example.com',
    );
    await _tap(tester, find.byKey(const ValueKey('widget-website-add')));
    expect(h.results, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('widget-website-url')),
      'https://example.com/page',
    );
    await _tap(tester, find.byKey(const ValueKey('widget-website-add')));
    expect(h.results.single.url, 'https://example.com/page');
    expect(h.container.exists(entitiesProvider), isFalse);
  });
  for (final size in [const Size(320, 900), const Size(1440, 1100)]) {
    testWidgets('gallery and device rows fit $size at 2x text', (tester) async {
      final h = _Harness();
      await h.mount(tester, size: size, scale: 2);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('widget-kind-camera')),
        200,
      );
      await _tap(tester, find.byKey(const ValueKey('widget-kind-camera')));
      expect(
        find.byKey(const ValueKey('widget-entity-camera.front')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('5000 entity choices build lazily', (tester) async {
    final h = _Harness();
    h.entities.values = {
      for (var i = 0; i < 5000; i++)
        'sensor.s$i': HaEntity(entityId: 'sensor.s$i', state: '$i'),
    };
    await h.mount(tester, initialType: TileType.entity);
    final choices = find.byWidgetPredicate(
      (widget) =>
          widget is CupertinoButton &&
          widget.key.toString().contains('widget-entity-'),
    );
    expect(choices.evaluate().length, lessThan(40));
    expect(h.results, isEmpty);
  });
  testWidgets('Home duplicate popup and selection produce one local save', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, home: true);
    final open = tester
        .widget<CupertinoButton>(
          find
              .ancestor(
                of: find.byIcon(CupertinoIcons.add_circled),
                matching: find.byType(CupertinoButton),
              )
              .first,
        )
        .onPressed!;
    open();
    open();
    await tester.pumpAndSettle();
    final popup = tester
        .widget<CupertinoActionSheetAction>(
          find.ancestor(
            of: find.text('Add Widget'),
            matching: find.byType(CupertinoActionSheetAction),
          ),
        )
        .onPressed;
    popup();
    popup();
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('widget-kind-entity')));
    await _tap(tester, find.byKey(const ValueKey('widget-entity-light.lamp')));
    expect(h.repository.writes, 1);
    expect(h.repository.saved.tiles, hasLength(1));
    expect(find.byType(HomeDashboardScreen), findsOneWidget);
  });
  testWidgets('queued local add rejects account change before durable write', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, home: true);
    await _tap(tester, find.byIcon(CupertinoIcons.add_circled).first);
    await _tap(tester, find.text('Add Widget'));
    await _tap(tester, find.byKey(const ValueKey('widget-kind-entity')));
    final release = Completer<void>();
    final blocked = ConfigurationWrites.run(() => release.future);
    await tester.tap(find.byKey(const ValueKey('widget-entity-light.lamp')));
    await tester.pumpAndSettle();
    h.connection.change();
    await tester.pumpAndSettle();
    release.complete();
    await blocked;
    await tester.pumpAndSettle();
    expect(h.repository.writes, 0);
    expect(h.repository.saved.tiles, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('local save failures are caught and leave dashboard unchanged', (
    tester,
  ) async {
    final h = _Harness();
    h.repository.fail = true;
    await h.mount(tester, home: true);
    await _tap(tester, find.byIcon(CupertinoIcons.add_circled).first);
    await _tap(tester, find.text('Add Widget'));
    await _tap(tester, find.byKey(const ValueKey('widget-kind-entity')));
    await _tap(tester, find.byKey(const ValueKey('widget-entity-light.lamp')));
    expect(h.repository.saved.tiles, isEmpty);
    expect(find.textContaining('private-storage'), findsNothing);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
