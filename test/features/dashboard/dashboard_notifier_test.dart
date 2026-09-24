import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/data/room_area_sync_reader.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/home_resources/domain/core_resource_binding.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';

class MemoryRepository extends DashboardRepository {
  DashboardLayout layout = const DashboardLayout(
    rooms: [DashboardRoom(id: 'room', name: 'Living room')],
  );
  Completer<void>? firstSave;
  int saveCount = 0;
  @override
  Future<DashboardLayout> load() async => layout;
  @override
  Future<void> save(DashboardLayout value, {bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) throw StateError('Expired');
    saveCount++;
    if (saveCount == 1) await firstSave?.future;
    if (isCurrent?.call() == false) throw StateError('Expired');
    layout = value;
  }
}

void main() {
  late ProviderContainer container;
  late MemoryRepository repository;
  setUp(() async {
    repository = MemoryRepository();
    container = ProviderContainer(
      overrides: [dashboardRepositoryProvider.overrideWithValue(repository)],
    );
    container.listen(dashboardLayoutProvider, (_, _) {});
    await container.read(dashboardLayoutProvider.future);
  });
  tearDown(() => container.dispose());

  test(
    'adding devices deduplicates incoming IDs and restores hidden devices',
    () async {
      final notifier = container.read(dashboardLayoutProvider.notifier);
      await notifier.hideEntity('light.a');
      await notifier.addEntitiesToRoom('room', [
        'light.a',
        'light.a',
        'light.b',
        '',
      ]);
      expect(repository.layout.rooms.single.entityIds, ['light.a', 'light.b']);
      expect(repository.layout.hiddenEntityIds, isEmpty);
    },
  );

  test(
    'Core room creation is atomic and rejects an expired interaction',
    () async {
      final binding = CoreResourceBinding(
        coreId: 'a' * 32,
        homeId: 'b' * 32,
        resourceId: 'c' * 32,
        kind: HomeResourceKind.room,
        resourceRevision: 2,
        aclRevision: 3,
        userRevision: 4,
      );
      final notifier = container.read(dashboardLayoutProvider.notifier);
      await expectLater(
        notifier.addCoreRoom('Denied', binding, isCurrent: () => false),
        throwsA(isA<RoomAreaSyncException>()),
      );
      expect(repository.layout.rooms, hasLength(1));

      await notifier.addCoreRoom('Core room', binding, isCurrent: () => true);
      expect(repository.layout.rooms, hasLength(2));
      expect(repository.layout.rooms.last.name, 'Core room');
      expect(repository.layout.rooms.last.entityIds, isEmpty);
      expect(repository.layout.rooms.last.coreResource, binding);
    },
  );

  test(
    'Core room binding uses compare-and-swap and detaches explicitly',
    () async {
      final binding = CoreResourceBinding(
        coreId: 'a' * 32,
        homeId: 'b' * 32,
        resourceId: 'c' * 32,
        kind: HomeResourceKind.room,
        resourceRevision: 2,
        aclRevision: 3,
        userRevision: 4,
      );
      final notifier = container.read(dashboardLayoutProvider.notifier);
      final original = repository.layout.rooms.single;
      await notifier.bindRoomToCoreResource(
        original,
        binding,
        isCurrent: () => true,
      );
      expect(repository.layout.rooms.single.coreResource, binding);
      await expectLater(
        notifier.bindRoomToCoreResource(
          original,
          binding,
          isCurrent: () => true,
        ),
        throwsA(isA<RoomAreaSyncException>()),
      );
      final bound = repository.layout.rooms.single;
      await notifier.detachRoomFromCoreResource(bound, isCurrent: () => true);
      expect(repository.layout.rooms.single.coreResource, isNull);
    },
  );

  test(
    'entity rename migrates all local references and deduplicates',
    () async {
      final notifier = container.read(dashboardLayoutProvider.notifier);
      await notifier.addEntitiesToRoom('room', ['light.old', 'light.new']);
      await notifier.toggleFavorite('light.old');
      await notifier.addTile(
        const TileConfig(
          id: 'tile',
          type: TileType.entity,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          entityId: 'light.old',
        ),
      );
      await notifier.renameEntityReferences('light.old', 'light.new');
      expect(repository.layout.rooms.single.entityIds, ['light.new']);
      expect(repository.layout.favoriteEntityIds, ['light.new']);
      expect(repository.layout.tiles.single.entityId, 'light.new');
      await notifier.hideEntity('light.new');
      await notifier.renameEntityReferences('light.new', 'light.final');
      expect(repository.layout.hiddenEntityIds, ['light.final']);
    },
  );

  test('blank names do not create or erase a room', () async {
    final notifier = container.read(dashboardLayoutProvider.notifier);
    await notifier.addRoom('  ');
    await notifier.renameRoom('room', '  ');
    expect(repository.layout.rooms.single.name, 'Living room');
  });

  test(
    'import is idempotent and merges trimmed case-insensitive names',
    () async {
      final notifier = container.read(dashboardLayoutProvider.notifier);
      await notifier.importRooms({
        ' living ROOM ': ['light.a', 'light.a'],
      });
      await notifier.importRooms({
        'Living room': ['light.a', 'light.b'],
      });
      expect(repository.layout.rooms, hasLength(1));
      expect(repository.layout.rooms.single.entityIds, ['light.a', 'light.b']);
    },
  );

  test(
    'concurrent edits persist in order without losing the newest state',
    () async {
      repository.firstSave = Completer<void>();
      final notifier = container.read(dashboardLayoutProvider.notifier);
      final first = notifier.renameRoom('room', 'First');
      final second = notifier.renameRoom('room', 'Latest');
      await Future<void>.delayed(Duration.zero);
      expect(repository.saveCount, 1);
      repository.firstSave!.complete();
      await Future.wait([first, second]);
      expect(repository.layout.rooms.single.name, 'Latest');
    },
  );
}
