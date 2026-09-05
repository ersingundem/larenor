import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/ha_area_binding.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/web_panel/domain/web_panel_options.dart';
import 'package:larenor/features/home_scope/data/legacy_layout_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = HomeDataScope.fromJson({
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'userId': 'one',
  });
  final legacy = DashboardLayout(
    rooms: [
      DashboardRoom(
        id: 'old-one',
        name: 'Kitchen',
        entityIds: ['light.private'],
      ),
      DashboardRoom(
        id: 'old-two',
        name: 'Living room',
        areaBinding: HaAreaBinding(
          serverUrl: 'https://private.example',
          areaId: 'private-area',
          sourceName: 'Living room',
        ),
      ),
      DashboardRoom(id: 'old-three', name: 'Office'),
    ],
    favoriteEntityIds: ['scene.private'],
    hiddenEntityIds: ['switch.private'],
  );
  late bool current;
  late DateTime now;
  late DashboardRepository destination;
  LegacyLayoutController controller() => LegacyLayoutController(
    destination: destination,
    isCurrent: () => current,
    clock: () => now,
  );
  setUp(() {
    current = true;
    now = DateTime.utc(2026, 9, 6);
    SharedPreferences.setMockInitialValues({
      'dashboard_layout': jsonEncode(legacy.toJson()),
    });
    destination = DashboardRepository.core(
      scope: scope,
      isCurrent: () => current,
    );
  });
  test('explicit preview copies selected passive room names in source order and appends', () async {
    await destination.save(
      const DashboardLayout(
        rooms: [DashboardRoom(id: 'existing', name: 'Existing')],
      ),
    );
    final c = controller();
    final preview = await c.preview();
    expect(preview.roomNames, ['Kitchen', 'Living room', 'Office']);
    expect(preview.currentRoomNames, ['Existing']);
    expect(preview.excludedEntityReferences, 3);
    expect(preview.excludedAreaBindings, 1);
    expect(preview.toString(), 'LegacyLayoutPreview');
    final before = (await SharedPreferences.getInstance()).getString(
      'dashboard_layout',
    );
    await c.apply(preview, {2, 0});
    final stored = await destination.load();
    expect(stored.rooms.map((r) => r.name), ['Existing', 'Kitchen', 'Office']);
    expect(
      stored.rooms
          .skip(1)
          .every((r) => r.entityIds.isEmpty && r.areaBinding == null),
      isTrue,
    );
    expect(stored.rooms.skip(1).map((r) => r.id), isNot(contains('old-one')));
    expect(stored.favoriteEntityIds, isEmpty);
    expect(stored.hiddenEntityIds, isEmpty);
    expect(stored.tiles, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString('dashboard_layout'),
      before,
    );
    await expectLater(
      c.apply(preview, {0}),
      throwsA(isA<DashboardStorageException>()),
    );
    expect((await destination.readSnapshot()).revision, 2);
  });
  for (final cause in [
    'source',
    'destination',
    'expiry',
    'clock-backwards',
    'authority',
    'owner',
    'closed',
  ]) {
    test('stale preview rejects $cause without writing', () async {
      final c = controller();
      final preview = await c.preview();
      switch (cause) {
        case 'source':
          await DashboardRepository().save(
            legacy.copyWith(rooms: legacy.rooms.reversed.toList()),
          );
        case 'destination':
          await destination.save(
            const DashboardLayout(
              rooms: [DashboardRoom(id: 'new', name: 'New')],
            ),
          );
        case 'expiry':
          now = now.add(const Duration(minutes: 5));
        case 'clock-backwards':
          now = now.subtract(const Duration(seconds: 1));
        case 'authority':
          current = false;
        case 'owner':
          break;
        case 'closed':
          c.close();
      }
      final prefs = await SharedPreferences.getInstance();
      final before = prefs.get(scope.storageKey);
      await expectLater(
        (cause == 'owner' ? controller() : c).apply(preview, {0}),
        throwsA(isA<DashboardStorageException>()),
      );
      await prefs.reload();
      expect(prefs.get(scope.storageKey), before);
    });
  }
  test('queued apply rechecks source and authority inside configuration transaction', () async {
    final c = controller();
    final preview = await c.preview();
    final entered = Completer<void>();
    final release = Completer<void>();
    final blocking = ConfigurationWrites.run(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final applying = c.apply(preview, {0});
    final rejected = expectLater(
      applying,
      throwsA(isA<DashboardStorageException>()),
    );
    current = false;
    release.complete();
    await blocking;
    await rejected;
    expect(
      (await SharedPreferences.getInstance()).get(scope.storageKey),
      isNull,
    );
  });
  test('invalid or empty selection never modifies destination', () async {
    for (final selection in [
      <int>{},
      {-1},
      {3},
    ]) {
      final c = controller();
      await expectLater(
        c.apply(await c.preview(), selection),
        throwsA(isA<DashboardStorageException>()),
      );
    }
    expect(
      (await SharedPreferences.getInstance()).get(scope.storageKey),
      isNull,
    );
  });

  test('web addresses, origins, scenes and service cards never enter passive destination', () async {
    final source = legacy.copyWith(
      tiles: [
        TileConfig(
          id: 'private-web',
          type: TileType.webview,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          url: 'https://private.example/panel?token=synthetic-secret',
          webPanel: WebPanelOptions(
            additionalOrigins: ['https://second.private.example'],
          ),
        ),
        const TileConfig(
          id: 'private-scene',
          type: TileType.scene,
          x: 1,
          y: 0,
          width: 1,
          height: 1,
          entityId: 'scene.private',
        ),
        const TileConfig(
          id: 'private-service',
          type: TileType.jellyfin,
          x: 2,
          y: 0,
          width: 1,
          height: 1,
        ),
      ],
    );
    await DashboardRepository().save(source);
    final c = controller();
    final preview = await c.preview();
    expect(preview.excludedCards, 3);
    await c.apply(preview, {1});
    final raw = (await SharedPreferences.getInstance()).getString(
      scope.storageKey,
    )!;
    for (final forbidden in [
      'private.example',
      'synthetic-secret',
      'private-scene',
      'jellyfin',
      'scene.private',
      'areaId',
      'old-two',
    ]) {
      expect(raw, isNot(contains(forbidden)));
    }
    expect((await destination.load()).rooms.single.name, 'Living room');
    expect(await DashboardRepository().load(), source);
  });
  test('target room cap is checked without partial append', () async {
    await destination.save(
      DashboardLayout(
        rooms: [
          for (var i = 0; i < 500; i++)
            DashboardRoom(id: 'existing-$i', name: 'Room $i'),
        ],
      ),
    );
    final c = controller();
    final preview = await c.preview();
    await expectLater(
      c.apply(preview, {0}),
      throwsA(
        isA<DashboardStorageException>().having(
          (e) => e.code,
          'code',
          'room_limit',
        ),
      ),
    );
    expect((await destination.readSnapshot()).revision, 1);
  });
}
