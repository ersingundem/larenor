import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/data/room_area_sync_reader.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_card_size.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/room_area_sync.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/dashboard/providers/room_area_sync_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';

class _Config extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async =>
      const HaConnectionConfig(baseUrl: 'http://ha.test', token: 'fixture');
  void change() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://other.test', token: 'other-fixture'),
  );
}

AreaSyncSnapshot _source({
  List<String> ids = const ['light.new'],
  bool missingArea = false,
}) => AreaSyncSnapshot(
  serverUrl: 'http://ha.test',
  areas: [if (!missingArea) const HaArea(areaId: 'salon', name: 'Salon')],
  devices: const [],
  registry: [
    for (final id in ids) HaRegistryEntry(entityId: id, areaId: 'salon'),
  ],
  entities: {for (final id in ids) id: HaEntity(entityId: id, state: 'off')},
);

class _Reader implements RoomAreaSyncReader {
  AreaSyncSnapshot value = _source();
  Future<AreaSyncSnapshot> Function()? nextRead;
  int reads = 0;
  @override
  Future<AreaSyncSnapshot> read() async {
    reads++;
    return nextRead == null ? value : nextRead!();
  }
}

class _Fixture {
  final repository = DashboardRepository();
  final reader = _Reader();
  var now = DateTime.utc(2026, 9, 5);
  late ProviderContainer container;
  late RoomAreaSyncController controller;
  static const initial = DashboardLayout(
    rooms: [
      DashboardRoom(id: 'room', name: 'Salon', entityIds: ['light.manual']),
      DashboardRoom(id: 'second', name: 'Kitchen'),
    ],
    entityCardSizes: {'light.manual': DashboardCardSize.large},
    serviceCardSizes: {'keenetic': DashboardCardSize.medium},
    favoriteEntityIds: ['light.manual'],
    hiddenEntityIds: ['light.new'],
    tiles: [
      TileConfig(
        id: 'web',
        type: TileType.webview,
        x: 0,
        y: 0,
        width: 2,
        height: 1,
        url: 'https://example.test',
      ),
    ],
  );
  Future<void> start() async {
    SharedPreferences.setMockInitialValues({});
    await repository.save(initial);
    container = ProviderContainer(
      overrides: [
        connectionConfigProvider.overrideWith(_Config.new),
        dashboardRepositoryProvider.overrideWithValue(repository),
        roomAreaSyncReaderProvider.overrideWithValue(reader),
        roomAreaSyncClockProvider.overrideWithValue(() => now),
      ],
    );
    await container.read(connectionConfigProvider.future);
    container.listen(dashboardLayoutProvider, (_, _) {});
    container.listen(roomAreaSyncControllerProvider, (_, _) {});
    await container.read(dashboardLayoutProvider.future);
    controller = container.read(roomAreaSyncControllerProvider);
    await container.read(roomAreaSyncSourceProvider.future);
  }

  Future<RoomAreaSyncPreview> preview() =>
      controller.preview(roomId: 'room', areaId: 'salon');
  void close() => container.dispose();
}

Matcher code(String code) =>
    isA<RoomAreaSyncException>().having((error) => error.code, 'code', code);

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture();
    await fixture.start();
  });
  tearDown(() => fixture.close());

  test('preview is read-only; apply changes local room only and rereads registries', () async {
    final preview = await fixture.preview();
    expect(await fixture.repository.load(), _Fixture.initial);
    expect(preview.change.added, ['light.new']);
    await fixture.controller.apply(preview);
    final result = await fixture.repository.load();
    expect(fixture.reader.reads, 2);
    expect(result.rooms.first.entityIds, ['light.manual', 'light.new']);
    expect(result.rooms.map((room) => room.id), ['room', 'second']);
    expect(result.favoriteEntityIds, _Fixture.initial.favoriteEntityIds);
    expect(result.hiddenEntityIds, _Fixture.initial.hiddenEntityIds);
    expect(result.tiles, _Fixture.initial.tiles);
    expect(result.entityCardSizes, _Fixture.initial.entityCardSizes);
    expect(result.serviceCardSizes, _Fixture.initial.serviceCardSizes);
    expect(result.rooms.first.areaBinding!.importedEntityIds, ['light.new']);
  });

  test('preview is single use', () async {
    final preview = await fixture.preview();
    await fixture.controller.apply(preview);
    await expectLater(
      fixture.controller.apply(preview),
      throwsA(code('preview_expired')),
    );
  });

  test('expired and backwards-clock previews cannot apply', () async {
    final preview = await fixture.preview();
    fixture.now = fixture.now.add(const Duration(minutes: 6));
    await expectLater(
      fixture.controller.apply(preview),
      throwsA(code('preview_expired')),
    );
    fixture.now = preview.createdAt.subtract(const Duration(seconds: 1));
    await expectLater(
      fixture.controller.apply(preview),
      throwsA(code('preview_expired')),
    );
    expect(await fixture.repository.load(), _Fixture.initial);
  });

  test(
    'account change rejects the old controller without disposed-ref errors',
    () async {
      final preview = await fixture.preview();
      (fixture.container.read(connectionConfigProvider.notifier) as _Config)
          .change();
      await fixture.container.pump();
      await expectLater(
        fixture.controller.apply(preview),
        throwsA(code('account_changed')),
      );
      expect(await fixture.repository.load(), _Fixture.initial);
    },
  );

  test(
    'source refresh invalidates previous preview even when contents are equal',
    () async {
      final preview = await fixture.preview();
      fixture.reader.value = _source();
      await fixture.container.refresh(roomAreaSyncSourceProvider.future);
      await expectLater(
        fixture.controller.apply(preview),
        throwsA(code('source_changed')),
      );
    },
  );

  test('changes discovered by fresh read must be previewed again', () async {
    final preview = await fixture.preview();
    fixture.reader.value = _source(ids: ['light.different']);
    await expectLater(
      fixture.controller.apply(preview),
      throwsA(code('source_changed')),
    );
    expect(await fixture.repository.load(), _Fixture.initial);
  });

  test('permission failure preserves the local layout and never appears as deletion', () async {
    final preview = await fixture.preview();
    fixture.reader.nextRead = () async =>
        throw const RoomAreaSyncException('permission');
    await expectLater(
      fixture.controller.apply(preview),
      throwsA(code('permission')),
    );
    expect(await fixture.repository.load(), _Fixture.initial);
  });

  test('deleted area cannot clear the local room', () async {
    fixture.reader.value = _source(missingArea: true);
    await fixture.container.refresh(roomAreaSyncSourceProvider.future);
    final preview = await fixture.preview();
    expect(preview.change.missingArea, isTrue);
    expect(preview.change.removed, isEmpty);
    await expectLater(
      fixture.controller.apply(preview),
      throwsA(code('missing_area')),
    );
    expect(await fixture.repository.load(), _Fixture.initial);
  });

  test(
    'room reorder invalidates whole-layout preview and preserves new order',
    () async {
      final preview = await fixture.preview();
      await fixture.container
          .read(dashboardLayoutProvider.notifier)
          .reorderRooms(0, 1);
      await expectLater(
        fixture.controller.apply(preview),
        throwsA(code('layout_changed')),
      );
      expect((await fixture.repository.load()).rooms.map((room) => room.id), [
        'second',
        'room',
      ]);
    },
  );

  test('fresh-read completion after account change cannot write', () async {
    final preview = await fixture.preview();
    final pending = Completer<AreaSyncSnapshot>();
    fixture.reader.nextRead = () => pending.future;
    final applying = fixture.controller.apply(preview);
    final rejected = expectLater(applying, throwsA(code('account_changed')));
    (fixture.container.read(connectionConfigProvider.notifier) as _Config)
        .change();
    await fixture.container.pump();
    pending.complete(_source());
    await rejected;
    expect(await fixture.repository.load(), _Fixture.initial);
  });

  test('account guard is checked again after waiting for global configuration writes', () async {
    final preview = await fixture.preview();
    final blocker = Completer<void>();
    final started = Completer<void>();
    final queued = ConfigurationWrites.run(() {
      started.complete();
      return blocker.future;
    });
    await started.future;
    final applying = fixture.controller.apply(preview);
    final rejected = expectLater(applying, throwsA(code('account_changed')));
    await Future<void>.delayed(Duration.zero);
    (fixture.container.read(connectionConfigProvider.notifier) as _Config)
        .change();
    await fixture.container.pump();
    blocker.complete();
    await queued;
    await rejected;
    expect(await fixture.repository.load(), _Fixture.initial);
  });

  test('an external local restore before apply is not overwritten', () async {
    final preview = await fixture.preview();
    const restored = DashboardLayout(
      rooms: [DashboardRoom(id: 'restored', name: 'Restored')],
    );
    await fixture.repository.save(restored);
    await expectLater(
      fixture.controller.apply(preview),
      throwsA(code('layout_changed')),
    );
    expect(await fixture.repository.load(), restored);
  });
}
