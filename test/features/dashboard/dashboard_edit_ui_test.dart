import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/data/room_area_sync_reader.dart';
import 'package:larenor/features/dashboard/domain/dashboard_card_size.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/ha_area_binding.dart';
import 'package:larenor/features/dashboard/domain/room_area_sync.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_card_editor_screen.dart';
import 'package:larenor/features/dashboard/presentation/home_dashboard_screen.dart';
import 'package:larenor/features/dashboard/presentation/room_area_sync_screen.dart';
import 'package:larenor/features/dashboard/presentation/tiles/home_accessory_tile.dart';
import 'package:larenor/features/dashboard/presentation/widgets/dashboard_grid_delegate.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/dashboard/providers/room_area_sync_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _config = HaConnectionConfig(
  baseUrl: 'http://home.invalid:8123',
  token: 'fixture',
);
const _room = DashboardRoom(
  id: 'room',
  name: 'Living room',
  entityIds: ['light.manual', 'light.existing'],
);
final _entities = <String, HaEntity>{
  for (final id in ['light.manual', 'light.existing', 'light.new'])
    id: HaEntity(
      entityId: id,
      state: 'off',
      attributes: {'friendly_name': 'Name $id'},
    ),
};
DashboardRoom _boundRoom() => _room.copyWith(
  areaBinding: HaAreaBinding(
    serverUrl: _config.baseUrl,
    areaId: 'living',
    sourceName: 'Living room',
    importedEntityIds: ['light.existing'],
  ),
);
AreaSyncSnapshot _source({bool missing = false, bool add = true}) =>
    AreaSyncSnapshot(
      serverUrl: _config.baseUrl,
      areas: missing
          ? []
          : [const HaArea(areaId: 'living', name: 'Living area')],
      devices: [],
      registry: [
        const HaRegistryEntry(entityId: 'light.existing', areaId: 'living'),
        if (add) const HaRegistryEntry(entityId: 'light.new', areaId: 'living'),
      ],
      entities: _entities,
    );

class _Repository extends DashboardRepository {
  _Repository(this.saved);
  DashboardLayout saved;
  int writes = 0;
  bool fail = false;
  @override
  Future<DashboardLayout> load() async => saved;
  @override
  Future<void> save(
    DashboardLayout layout, {
    bool Function()? isCurrent,
  }) async {
    if (fail || isCurrent?.call() == false) {
      throw StateError('private-storage-detail');
    }
    saved = layout;
    writes++;
  }
}

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => _config;
  void change() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://other.invalid', token: 'other'),
  );
  void loading() => state = const AsyncLoading();
}

class _Entities extends Entities {
  int actions = 0;
  @override
  Future<Map<String, HaEntity>> build() async => _entities;
  @override
  Future<void> toggle(HaEntity entity) async {
    actions++;
  }
}

class _Reader implements RoomAreaSyncReader {
  AreaSyncSnapshot source = _source();
  int reads = 0;
  Future<AreaSyncSnapshot> Function()? onRead;
  @override
  Future<AreaSyncSnapshot> read() async {
    reads++;
    return onRead?.call() ?? source;
  }
}

class _Harness {
  _Harness([DashboardLayout? layout])
    : repository = _Repository(layout ?? const DashboardLayout(rooms: [_room]));
  final _Repository repository;
  final connection = _Connection();
  final entities = _Entities();
  final reader = _Reader();
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    bool passive = false,
    Size size = const Size(800, 1100),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        dashboardRepositoryProvider.overrideWithValue(repository),
        connectionConfigProvider.overrideWith(() => connection),
        entitiesProvider.overrideWith(() => entities),
        roomAreaSyncReaderProvider.overrideWithValue(reader),
        enabledServicesProvider.overrideWithBuild((ref, notifier) async => {}),
        haConnectionStatusProvider.overrideWith(
          (ref) => Stream.value(HaConnectionStatus.connected),
        ),
      ],
    );
    addTearDown(container.dispose);
    if (!passive) {
      await container.read(connectionConfigProvider.future);
      await container.read(entitiesProvider.future);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _preview(WidgetTester tester) async {
  if (find
      .byKey(const ValueKey('room-sync-area-living'))
      .evaluate()
      .isNotEmpty) {
    await _tap(tester, 'room-sync-area-living');
  }
  await _tap(tester, 'room-sync-preview');
}

void main() {
  testWidgets(
    '5000 editor rows stay lazy and do not initialize network providers',
    (tester) async {
      final harness = _Harness(
        DashboardLayout(
          rooms: [
            DashboardRoom(
              id: 'room',
              name: 'Large room',
              entityIds: List.generate(5000, (i) => 'light.item_$i'),
            ),
          ],
        ),
      );
      await harness.mount(
        tester,
        const DashboardCardEditorScreen(
          mode: DashboardEditorMode.room,
          roomId: 'room',
        ),
        passive: true,
      );
      expect(find.byType(LiveHomeAccessoryTile), findsNothing);
      expect(
        find.byType(ReorderableDragStartListener).evaluate().length,
        lessThan(30),
      );
      expect(harness.container.exists(entitiesProvider), isFalse);
      expect(harness.container.exists(haRestClientProvider), isFalse);
      expect(harness.container.exists(haWebSocketClientProvider), isFalse);
      expect(harness.container.exists(qbittorrentClientProvider), isFalse);
      expect(harness.repository.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'room editor reorders hidden/manual members and saves one size override',
    (tester) async {
      final harness = _Harness(
        const DashboardLayout(
          rooms: [_room],
          hiddenEntityIds: ['light.existing'],
          favoriteEntityIds: ['light.manual'],
        ),
      );
      await harness.mount(
        tester,
        const DashboardCardEditorScreen(
          mode: DashboardEditorMode.room,
          roomId: 'room',
        ),
      );
      await _tap(tester, 'dashboard-edit-down-light.manual');
      expect(harness.repository.saved.rooms.single.entityIds, [
        'light.existing',
        'light.manual',
      ]);
      expect(harness.repository.saved.hiddenEntityIds, ['light.existing']);
      expect(harness.repository.saved.favoriteEntityIds, ['light.manual']);
      await _tap(tester, 'dashboard-edit-size-light.manual');
      await _tap(tester, 'dashboard-size-medium');
      expect(
        harness.repository.saved.entityCardSizes['light.manual'],
        DashboardCardSize.medium,
      );
      expect(harness.entities.actions, 0);
    },
  );

  testWidgets(
    'widget editor preserves legacy dimensions until explicit size selection',
    (tester) async {
      final harness = _Harness(
        const DashboardLayout(
          tiles: [
            TileConfig(
              id: 'one',
              type: TileType.history,
              x: 0,
              y: 0,
              width: 3,
              height: 2,
              entityId: 'sensor.a',
            ),
            TileConfig(
              id: 'two',
              type: TileType.camera,
              x: 0,
              y: 0,
              width: 2,
              height: 2,
              entityId: 'camera.a',
            ),
          ],
        ),
      );
      await harness.mount(
        tester,
        const DashboardCardEditorScreen(mode: DashboardEditorMode.widgets),
        passive: true,
      );
      expect(harness.repository.saved.tiles.first.width, 3);
      await _tap(tester, 'dashboard-edit-size-one');
      await _tap(tester, 'dashboard-size-large');
      await _tap(tester, 'dashboard-edit-down-one');
      expect(harness.repository.saved.tiles.map((tile) => tile.id), [
        'two',
        'one',
      ]);
      expect(harness.repository.saved.tiles.last.width, 2);
      expect(harness.repository.saved.tiles.last.height, 2);
      expect(harness.container.exists(entitiesProvider), isFalse);
    },
  );

  testWidgets(
    'service editor changes only the local size map and remains passive',
    (tester) async {
      final harness = _Harness();
      await harness.mount(
        tester,
        const DashboardCardEditorScreen(
          mode: DashboardEditorMode.services,
          services: [AppService.qbittorrent],
        ),
        passive: true,
      );
      await _tap(tester, 'dashboard-edit-size-qbittorrent');
      await _tap(tester, 'dashboard-size-large');
      expect(harness.repository.saved.serviceCardSizes, {
        'qbittorrent': DashboardCardSize.large,
      });
      expect(harness.container.exists(qbittorrentClientProvider), isFalse);
      expect(harness.container.exists(haRestClientProvider), isFalse);
    },
  );

  testWidgets('home uses real spans and keeps 5000 accessories lazy', (
    tester,
  ) async {
    final harness = _Harness(
      DashboardLayout(
        rooms: [
          DashboardRoom(
            id: 'room',
            name: 'Large',
            entityIds: List.generate(5000, (i) => 'light.item_$i'),
          ),
        ],
        entityCardSizes: {
          'light.item_1': DashboardCardSize.medium,
          'light.item_2': DashboardCardSize.large,
        },
      ),
    );
    await harness.mount(tester, const HomeDashboardScreen());
    final grid =
        tester.widget<SliverGrid>(find.byType(SliverGrid).first).gridDelegate
            as DashboardGridDelegate;
    expect(grid.spans.take(3), [
      const DashboardGridSpan(1, 1),
      const DashboardGridSpan(2, 1),
      const DashboardGridSpan(2, 2),
    ]);
    expect(find.byType(LiveHomeAccessoryTile).evaluate().length, lessThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'area preview is explicit and apply preserves manual membership',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester, const RoomAreaSyncScreen(roomId: 'room'));
      await _preview(tester);
      expect(harness.repository.writes, 0);
      expect(find.text('To add: 1'), findsOneWidget);
      expect(
        find.textContaining(
          'Home Assistant areas and devices are not changed.',
        ),
        findsOneWidget,
      );
      await _tap(tester, 'room-sync-apply');
      expect(harness.reader.reads, 2);
      expect(harness.repository.saved.rooms.single.entityIds, [
        'light.manual',
        'light.existing',
        'light.new',
      ]);
      expect(
        harness.repository.saved.rooms.single.areaBinding!.importedEntityIds,
        ['light.new'],
      );
      expect(harness.entities.actions, 0);
    },
  );

  testWidgets(
    'changed source during apply rejects the stale preview without saving',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester, const RoomAreaSyncScreen(roomId: 'room'));
      await _preview(tester);
      harness.reader.source = _source(add: false);
      await _tap(tester, 'room-sync-apply');
      expect(harness.repository.writes, 0);
      expect(find.textContaining('Create a fresh preview'), findsOneWidget);
      expect(harness.repository.saved.rooms.single, _room);
    },
  );

  testWidgets('account change invalidates a captured apply callback', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester, const RoomAreaSyncScreen(roomId: 'room'));
    await _preview(tester);
    final apply = tester
        .widget<CupertinoButton>(find.byKey(const ValueKey('room-sync-apply')))
        .onPressed!;
    harness.connection.change();
    await tester.pumpAndSettle();
    apply();
    await tester.pumpAndSettle();
    expect(harness.repository.writes, 0);
    expect(find.byKey(const ValueKey('room-sync-apply')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing area preserves every member and disables apply', (
    tester,
  ) async {
    final room = _boundRoom();
    final harness = _Harness(DashboardLayout(rooms: [room]))
      ..reader.source = _source(missing: true);
    await harness.mount(tester, const RoomAreaSyncScreen(roomId: 'room'));
    await _preview(tester);
    expect(
      find.textContaining('The room and its devices are preserved.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('room-sync-apply')),
          )
          .onPressed,
      isNull,
    );
    expect(harness.repository.writes, 0);
    expect(harness.repository.saved.rooms.single, room);
  });

  testWidgets(
    'unbind confirmation keeps room order, members and hidden preferences',
    (tester) async {
      final room = _boundRoom();
      final harness = _Harness(
        DashboardLayout(rooms: [room], hiddenEntityIds: ['light.existing']),
      );
      await harness.mount(tester, const RoomAreaSyncScreen(roomId: 'room'));
      await _tap(tester, 'room-sync-unbind');
      expect(harness.repository.writes, 0);
      await _tap(tester, 'room-sync-confirm-unbind');
      expect(harness.repository.saved.rooms.single.areaBinding, isNull);
      expect(harness.repository.saved.rooms.single.entityIds, room.entityIds);
      expect(harness.repository.saved.hiddenEntityIds, ['light.existing']);
    },
  );

  testWidgets(
    'bound room account mismatch removes live controls and stale tap cannot act',
    (tester) async {
      final harness = _Harness(DashboardLayout(rooms: [_boundRoom()]));
      await harness.mount(tester, const HomeDashboardScreen());
      final tile = find.byType(HomeAccessoryTile).first;
      final gesture = find
          .descendant(of: tile, matching: find.byType(GestureDetector))
          .first;
      final tap = tester.widget<GestureDetector>(gesture).onTap!;
      harness.connection.change();
      await tester.pumpAndSettle();
      expect(find.byType(LiveHomeAccessoryTile), findsNothing);
      expect(
        find.textContaining('This room belongs to another Home Assistant'),
        findsOneWidget,
      );
      tap();
      await tester.pumpAndSettle();
      expect(harness.entities.actions, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bound room loading connection never leaves old controls active',
    (tester) async {
      final harness = _Harness(DashboardLayout(rooms: [_boundRoom()]));
      await harness.mount(tester, const HomeDashboardScreen());
      harness.connection.loading();
      await tester.pump();
      expect(find.byType(LiveHomeAccessoryTile), findsNothing);
      expect(harness.entities.actions, 0);
    },
  );

  testWidgets(
    'size picker cancellation and failed storage never execute a device',
    (tester) async {
      final harness = _Harness();
      await harness.mount(
        tester,
        const DashboardCardEditorScreen(
          mode: DashboardEditorMode.room,
          roomId: 'room',
        ),
      );
      await _tap(tester, 'dashboard-edit-size-light.manual');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(harness.repository.writes, 0);
      harness.repository.fail = true;
      await _tap(tester, 'dashboard-edit-size-light.manual');
      await _tap(tester, 'dashboard-size-large');
      expect(
        find.textContaining('The layout could not be saved.'),
        findsOneWidget,
      );
      expect(find.textContaining('private-storage-detail'), findsNothing);
      expect(harness.entities.actions, 0);
    },
  );

  testWidgets('legacy 100 by 100 widget dimensions are bounded for rendering', (
    tester,
  ) async {
    final harness = _Harness(
      const DashboardLayout(
        tiles: [
          TileConfig(
            id: 'oversize',
            type: TileType.entity,
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            entityId: 'light.manual',
          ),
        ],
      ),
    );
    await harness.mount(tester, const HomeDashboardScreen());
    final grid =
        tester.widget<SliverGrid>(find.byType(SliverGrid).last).gridDelegate
            as DashboardGridDelegate;
    expect(grid.spans.single, const DashboardGridSpan(6, 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'size selection preserves a widget changed while the modal was open',
    (tester) async {
      const tile = TileConfig(
        id: 'one',
        type: TileType.webview,
        x: 0,
        y: 0,
        width: 3,
        height: 2,
        title: 'Before',
        url: 'https://before.invalid',
      );
      final harness = _Harness(const DashboardLayout(tiles: [tile]));
      await harness.mount(
        tester,
        const DashboardCardEditorScreen(mode: DashboardEditorMode.widgets),
        passive: true,
      );
      await _tap(tester, 'dashboard-edit-size-one');
      await harness.container
          .read(dashboardLayoutProvider.notifier)
          .updateTile(
            tile.copyWith(title: 'After', url: 'https://after.invalid'),
          );
      await tester.pump();
      await _tap(tester, 'dashboard-size-small');
      expect(harness.repository.saved.tiles.single.title, 'After');
      expect(
        harness.repository.saved.tiles.single.url,
        'https://after.invalid',
      );
      expect(harness.repository.saved.tiles.single.width, 1);
    },
  );

  testWidgets('a size dialog callback cannot write after the account changes', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(
      tester,
      const DashboardCardEditorScreen(
        mode: DashboardEditorMode.room,
        roomId: 'room',
      ),
    );
    await _tap(tester, 'dashboard-edit-size-light.manual');
    final choose = tester
        .widget<CupertinoActionSheetAction>(
          find.byKey(const ValueKey('dashboard-size-large')),
        )
        .onPressed;
    harness.connection.change();
    await tester.pumpAndSettle();
    choose();
    await tester.pumpAndSettle();
    expect(harness.repository.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'backgrounding expires an area preview before a saved callback can apply',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester, const RoomAreaSyncScreen(roomId: 'room'));
      await _preview(tester);
      final apply = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('room-sync-apply')),
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
        await tester.pump();
      }
      apply();
      await tester.pumpAndSettle();
      expect(harness.repository.writes, 0);
      expect(find.byKey(const ValueKey('room-sync-apply')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Home room menu opens the local card editor', (tester) async {
    final harness = _Harness();
    await harness.mount(tester, const HomeDashboardScreen());
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle).first);
    await tester.pumpAndSettle();
    await _tap(tester, 'room-menu-edit');
    expect(find.byType(DashboardCardEditorScreen), findsOneWidget);
    expect(harness.entities.actions, 0);
  });

  testWidgets('room menu moves its selected room after another reorder', (
    tester,
  ) async {
    final harness = _Harness(
      const DashboardLayout(
        rooms: [
          DashboardRoom(id: 'first', name: 'First'),
          DashboardRoom(id: 'middle', name: 'Middle'),
          DashboardRoom(id: 'last', name: 'Last'),
        ],
      ),
    );
    await harness.mount(tester, const HomeDashboardScreen());
    await _tap(tester, 'home-room-menu-middle');
    await harness.container
        .read(dashboardLayoutProvider.notifier)
        .reorderRooms(1, 2);
    await tester.pump();
    await _tap(tester, 'room-menu-up');
    expect(harness.repository.saved.rooms.map((room) => room.id), [
      'first',
      'middle',
      'last',
    ]);
  });

  for (final size in [const Size(320, 900), const Size(1100, 1000)]) {
    testWidgets('area preview fits ${size.width}px at 2x text', (tester) async {
      final harness = _Harness();
      await harness.mount(
        tester,
        const RoomAreaSyncScreen(roomId: 'room'),
        size: size,
        scale: 2,
      );
      await _preview(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('room-sync-apply')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('editor fits ${size.width}px at 2x text', (tester) async {
      final harness = _Harness();
      await harness.mount(
        tester,
        const DashboardCardEditorScreen(
          mode: DashboardEditorMode.room,
          roomId: 'room',
        ),
        size: size,
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, 'dashboard-edit-size-light.manual');
      expect(tester.takeException(), isNull);
    });
  }
}
