import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/data/room_area_sync_reader.dart';
import 'package:larenor/features/dashboard/domain/dashboard_card_size.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/settings/data/app_service.dart';

void main() {
  late ProviderContainer container;
  late DashboardRepository repository;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = DashboardRepository();
    await repository.save(
      const DashboardLayout(
        rooms: [
          DashboardRoom(
            id: 'room',
            name: 'Salon',
            entityIds: ['light.a', 'light.hidden', 'light.b'],
          ),
        ],
        hiddenEntityIds: ['light.hidden'],
        favoriteEntityIds: ['light.b'],
        tiles: [
          TileConfig(
            id: 'one',
            type: TileType.history,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            entityId: 'light.a',
          ),
          TileConfig(
            id: 'two',
            type: TileType.webview,
            x: 1,
            y: 0,
            width: 1,
            height: 1,
            url: 'https://example.test',
          ),
        ],
      ),
    );
    container = ProviderContainer(
      overrides: [dashboardRepositoryProvider.overrideWithValue(repository)],
    );
    container.listen(dashboardLayoutProvider, (_, _) {});
    await container.read(dashboardLayoutProvider.future);
  });
  tearDown(() => container.dispose());

  test('logical size overrides persist across JSON and backup; null resets only one preference', () async {
    final notifier = container.read(dashboardLayoutProvider.notifier);
    await notifier.setEntityCardSize('light.a', DashboardCardSize.large);
    await notifier.setEntityCardSize('light.b', DashboardCardSize.small);
    await notifier.setServiceCardSize(
      AppService.keenetic,
      DashboardCardSize.medium,
    );
    final layout = await repository.load();
    expect(layout.entityCardSizes, {
      'light.a': DashboardCardSize.large,
      'light.b': DashboardCardSize.small,
    });
    expect(layout.serviceCardSizes, {'keenetic': DashboardCardSize.medium});
    final json =
        jsonDecode(jsonEncode(layout.toJson())) as Map<String, dynamic>;
    validateDashboardLayoutJson(json);
    expect(
      BackupSnapshot.fromJson({
        'version': 1,
        'createdAt': '2026-09-05T00:00:00Z',
        'groups': {'dashboard': json},
      }).hasDashboard,
      isTrue,
    );
    await notifier.setEntityCardSize('light.a', null);
    await notifier.setServiceCardSize(AppService.keenetic, null);
    final reset = await repository.load();
    expect(reset.entityCardSizes, {'light.b': DashboardCardSize.small});
    expect(reset.serviceCardSizes, isEmpty);
  });

  test(
    'reorder preserves hidden IDs, favorites, sizes and the full widget data',
    () async {
      final notifier = container.read(dashboardLayoutProvider.notifier);
      await notifier.setEntityCardSize('light.a', DashboardCardSize.large);
      await notifier.reorderEntitiesInRoom('room', [
        'light.b',
        'light.a',
        'light.hidden',
      ]);
      await notifier.reorderTiles(['two', 'one']);
      final layout = await repository.load();
      expect(layout.rooms.single.entityIds, [
        'light.b',
        'light.a',
        'light.hidden',
      ]);
      expect(layout.hiddenEntityIds, ['light.hidden']);
      expect(layout.favoriteEntityIds, ['light.b']);
      expect(layout.entityCardSizes['light.a'], DashboardCardSize.large);
      expect(layout.tiles.map((tile) => tile.id), ['two', 'one']);
      expect(layout.tiles.first.url, 'https://example.test');
      expect(layout.tiles.last.entityId, 'light.a');
    },
  );

  test('incomplete, duplicated and stale reorder lists cannot delete or overwrite data', () async {
    final notifier = container.read(dashboardLayoutProvider.notifier);
    final original = await repository.load();
    for (final ids in [
      ['light.b', 'light.a'],
      ['light.a', 'light.a', 'light.b'],
      ['light.a', 'light.hidden', 'light.foreign'],
    ]) {
      await expectLater(
        notifier.reorderEntitiesInRoom('room', ids),
        throwsA(isA<RoomAreaSyncException>()),
      );
    }
    await expectLater(
      notifier.reorderTiles(['one']),
      throwsA(isA<RoomAreaSyncException>()),
    );
    await expectLater(
      notifier.reorderTiles(['one', 'one']),
      throwsA(isA<RoomAreaSyncException>()),
    );
    expect(await repository.load(), original);
  });

  test('entity rename moves a size override but preserves a preexisting destination preference', () async {
    final notifier = container.read(dashboardLayoutProvider.notifier);
    await notifier.setEntityCardSize('light.a', DashboardCardSize.large);
    await notifier.setEntityCardSize('light.b', DashboardCardSize.small);
    await notifier.renameEntityReferences('light.a', 'light.b');
    expect((await repository.load()).entityCardSizes, {
      'light.b': DashboardCardSize.small,
    });
    await notifier.renameEntityReferences('light.b', 'light.renamed');
    expect((await repository.load()).entityCardSizes, {
      'light.renamed': DashboardCardSize.small,
    });
  });

  for (final invalid in [
    {
      'entityCardSizes': {'light.a': 'huge'},
    },
    {
      'entityCardSizes': {'light.a/../secret': 'small'},
    },
    {
      'entityCardSizes': {'light.a': 2},
    },
    {
      'serviceCardSizes': {'custom': 'large'},
    },
    {
      'serviceCardSizes': {'keenetic': 'automatic'},
    },
  ]) {
    test('local and backup sizes reject unsupported map $invalid', () {
      expect(() => validateDashboardLayoutJson(invalid), throwsFormatException);
      expect(
        () => BackupSnapshot.fromJson({
          'version': 1,
          'createdAt': '2026-09-05T00:00:00Z',
          'groups': {'dashboard': invalid},
        }),
        throwsA(isA<BackupValidationException>()),
      );
    });
  }
}
