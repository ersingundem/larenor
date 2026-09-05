import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/data/room_area_sync_reader.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/ha_area_binding.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';

DashboardRoom _room({String id = 'room', String server = 'http://ha.test'}) =>
    DashboardRoom(
      id: id,
      name: 'Salon',
      entityIds: ['light.imported', 'light.manual'],
      areaBinding: HaAreaBinding(
        serverUrl: server,
        areaId: 'salon',
        sourceName: 'Salon',
        importedEntityIds: ['light.imported'],
        excludedEntityIds: ['light.excluded'],
      ),
    );

void main() {
  test(
    'queued rename checks captured account guard before any persistence',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repository = DashboardRepository();
      final initial = DashboardLayout(rooms: [_room()]);
      await repository.save(initial);
      final container = ProviderContainer(
        overrides: [dashboardRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      container.listen(dashboardLayoutProvider, (_, _) {});
      await container.read(dashboardLayoutProvider.future);
      final blocked = Completer<void>();
      final started = Completer<void>();
      final blocker = ConfigurationWrites.run(() {
        started.complete();
        return blocked.future;
      });
      await started.future;
      var currentAccount = true;
      final pending = container
          .read(dashboardLayoutProvider.notifier)
          .renameEntityReferences(
            'light.imported',
            'light.new',
            serverUrl: 'http://ha.test',
            isCurrent: () => currentAccount,
          );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<RoomAreaSyncException>().having(
            (error) => error.code,
            'code',
            'account_changed',
          ),
        ),
      );
      currentAccount = false;
      blocked.complete();
      await blocker;
      await rejected;
      expect(await repository.load(), initial);
      expect(container.read(dashboardLayoutProvider).value, initial);
    },
  );
  late ProviderContainer container;
  late DashboardRepository repository;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = DashboardRepository();
    await repository.save(DashboardLayout(rooms: [_room()]));
    container = ProviderContainer(
      overrides: [dashboardRepositoryProvider.overrideWithValue(repository)],
    );
    container.listen(dashboardLayoutProvider, (_, _) {});
    await container.read(dashboardLayoutProvider.future);
  });
  tearDown(() => container.dispose());

  test('manual addition promotes imported membership and reverses explicit exclusion', () async {
    await container.read(dashboardLayoutProvider.notifier).addEntitiesToRoom(
      'room',
      ['light.imported', 'light.excluded'],
    );
    final room = (await repository.load()).rooms.single;
    expect(room.entityIds, [
      'light.imported',
      'light.manual',
      'light.excluded',
    ]);
    expect(room.areaBinding!.importedEntityIds, isEmpty);
    expect(room.areaBinding!.excludedEntityIds, isEmpty);
  });

  test(
    'manual removal records exclusion to stop future automatic readdition',
    () async {
      await container
          .read(dashboardLayoutProvider.notifier)
          .removeEntityFromRoom('room', 'light.imported');
      final room = (await repository.load()).rooms.single;
      expect(room.entityIds, ['light.manual']);
      expect(room.areaBinding!.importedEntityIds, isEmpty);
      expect(room.areaBinding!.excludedEntityIds, [
        'light.excluded',
        'light.imported',
      ]);
    },
  );

  test(
    'detach keeps local member ordering and turns every member manual',
    () async {
      await container
          .read(dashboardLayoutProvider.notifier)
          .detachRoomArea('room');
      final room = (await repository.load()).rooms.single;
      expect(room.entityIds, ['light.imported', 'light.manual']);
      expect(room.areaBinding, isNull);
    },
  );

  test('renamed HA references update only the bound server with correct provenance', () async {
    await repository.save(
      DashboardLayout(
        rooms: [
          _room(),
          _room(id: 'other', server: 'http://other.test'),
        ],
      ),
    );
    await container
        .read(dashboardLayoutProvider.notifier)
        .renameEntityReferences(
          'light.imported',
          'light.renamed',
          serverUrl: 'http://ha.test/',
        );
    final rooms = (await repository.load()).rooms;
    expect(rooms.first.entityIds, ['light.renamed', 'light.manual']);
    expect(rooms.first.areaBinding!.importedEntityIds, ['light.renamed']);
    expect(rooms.last.entityIds, ['light.imported', 'light.manual']);
    expect(rooms.last.areaBinding!.importedEntityIds, ['light.imported']);
  });

  test('room reorder keeps membership provenance ordered so the next sync is stable', () async {
    final room = DashboardRoom(
      id: 'room',
      name: 'Salon',
      entityIds: ['light.a', 'light.b'],
      areaBinding: HaAreaBinding(
        serverUrl: 'http://ha.test',
        areaId: 'salon',
        sourceName: 'Salon',
        importedEntityIds: ['light.a', 'light.b'],
      ),
    );
    await repository.save(DashboardLayout(rooms: [room]));
    await container
        .read(dashboardLayoutProvider.notifier)
        .reorderEntitiesInRoom('room', ['light.b', 'light.a']);
    expect(
      (await repository.load()).rooms.single.areaBinding!.importedEntityIds,
      ['light.b', 'light.a'],
    );
  });

  test('legacy rename without a server never changes bound rooms', () async {
    await container
        .read(dashboardLayoutProvider.notifier)
        .renameEntityReferences('light.imported', 'light.new');
    expect((await repository.load()).rooms.single.entityIds, [
      'light.imported',
      'light.manual',
    ]);
  });

  test(
    'rename collision with a manual member does not make it imported',
    () async {
      await container
          .read(dashboardLayoutProvider.notifier)
          .renameEntityReferences(
            'light.imported',
            'light.manual',
            serverUrl: 'http://ha.test',
          );
      final room = (await repository.load()).rooms.single;
      expect(room.entityIds, ['light.manual']);
      expect(room.areaBinding!.importedEntityIds, isEmpty);
    },
  );

  test(
    'different concurrent edits derive from the latest durable layout',
    () async {
      final blocked = Completer<void>();
      final started = Completer<void>();
      final blocker = ConfigurationWrites.run(() {
        started.complete();
        return blocked.future;
      });
      await started.future;
      final notifier = container.read(dashboardLayoutProvider.notifier);
      final first = notifier.renameRoom('room', 'Manual name');
      final second = notifier.addEntitiesToRoom('room', ['light.added']);
      blocked.complete();
      await blocker;
      await Future.wait([first, second]);
      final room = (await repository.load()).rooms.single;
      expect(room.name, 'Manual name');
      expect(room.entityIds, ['light.imported', 'light.manual', 'light.added']);
    },
  );

  test('a queued local edit transforms restored data instead of replacing it with stale state', () async {
    final notifier = container.read(dashboardLayoutProvider.notifier);
    final restored = DashboardLayout(
      rooms: [
        _room(),
        const DashboardRoom(id: 'restored', name: 'Restored'),
      ],
      favoriteEntityIds: ['light.restored'],
    );
    final restore = ConfigurationWrites.run(() => repository.save(restored));
    final edit = notifier.renameRoom('room', 'After restore');
    await Future.wait([restore, edit]);
    final layout = await repository.load();
    expect(layout.rooms.map((room) => room.id), ['room', 'restored']);
    expect(layout.rooms.first.name, 'After restore');
    expect(layout.favoriteEntityIds, ['light.restored']);
  });
}
