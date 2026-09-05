import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/data/models/ha_device.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/ha_area_binding.dart';
import 'package:larenor/features/dashboard/domain/room_area_sync.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';

const server = 'http://ha.test';
DashboardRoom room({
  String name = 'Salon',
  List<String> ids = const ['light.manual', 'light.old'],
  List<String> imported = const ['light.old'],
  List<String> excluded = const [],
}) => DashboardRoom(
  id: 'room',
  name: name,
  entityIds: ids,
  areaBinding: HaAreaBinding(
    serverUrl: server,
    areaId: 'salon',
    sourceName: 'Salon',
    importedEntityIds: imported,
    excludedEntityIds: excluded,
  ),
);
AreaSyncSnapshot snapshot({
  List<HaArea> areas = const [HaArea(areaId: 'salon', name: 'Salon')],
  List<HaDevice> devices = const [],
  List<HaRegistryEntry> entries = const [],
  Map<String, HaEntity>? entities,
}) => AreaSyncSnapshot(
  serverUrl: server,
  areas: areas,
  devices: devices,
  registry: entries,
  entities:
      entities ??
      {
        for (final entry in entries)
          entry.entityId: HaEntity(entityId: entry.entityId, state: 'off'),
      },
);
RoomAreaSyncChange change(DashboardRoom before, AreaSyncSnapshot source) =>
    buildRoomAreaSyncChange(room: before, snapshot: source, areaId: 'salon');

void main() {
  test(
    'direct area takes precedence; device fallback works; order is stable',
    () {
      final result = change(
        room(),
        snapshot(
          devices: const [HaDevice(id: 'device', areaId: 'salon')],
          entries: const [
            HaRegistryEntry(entityId: 'light.z', areaId: 'salon'),
            HaRegistryEntry(entityId: 'light.b', deviceId: 'device'),
            HaRegistryEntry(
              entityId: 'light.out',
              areaId: 'kitchen',
              deviceId: 'device',
            ),
          ],
        ),
      );
      expect(result.after.entityIds, ['light.manual', 'light.b', 'light.z']);
      expect(result.added, ['light.b', 'light.z']);
      expect(result.removed, ['light.old']);
      expect(result.after.areaBinding!.importedEntityIds, [
        'light.b',
        'light.z',
      ]);
    },
  );

  test('missing state, unavailable and disabled imported members remain', () {
    final result = change(
      room(
        ids: ['light.old', 'light.offline'],
        imported: ['light.old', 'light.offline'],
      ),
      snapshot(
        entries: const [
          HaRegistryEntry(
            entityId: 'light.old',
            areaId: 'salon',
            disabledBy: 'user',
          ),
          HaRegistryEntry(
            entityId: 'light.offline',
            areaId: 'salon',
            hiddenBy: 'user',
          ),
        ],
        entities: const {
          'light.offline': HaEntity(
            entityId: 'light.offline',
            state: 'unavailable',
          ),
        },
      ),
    );
    expect(result.after.entityIds, ['light.old', 'light.offline']);
    expect(result.removed, isEmpty);
  });

  test(
    'missing device is unknown and retained; a known area move is removable',
    () {
      final result = change(
        room(
          ids: ['light.old', 'light.move'],
          imported: ['light.old', 'light.move'],
        ),
        snapshot(
          entries: const [
            HaRegistryEntry(entityId: 'light.old', deviceId: 'missing'),
            HaRegistryEntry(entityId: 'light.move', areaId: 'kitchen'),
          ],
        ),
      );
      expect(result.heldUnknown, ['light.old']);
      expect(result.after.entityIds, ['light.old']);
      expect(result.removed, ['light.move']);
    },
  );

  test('deleted area preserves all local contents and binding', () {
    final before = room();
    final result = change(before, snapshot(areas: const []));
    expect(result.missingArea, isTrue);
    expect(result.after, before);
    expect(result.hasChanges, isFalse);
    expect(result.removed, isEmpty);
  });

  test('manual and excluded membership survives repeat import', () {
    final before = room(
      ids: ['light.manual', 'light.old'],
      excluded: ['light.skip'],
    );
    final source = snapshot(
      entries: const [
        HaRegistryEntry(entityId: 'light.manual', areaId: 'salon'),
        HaRegistryEntry(entityId: 'light.old', areaId: 'salon'),
        HaRegistryEntry(entityId: 'light.skip', areaId: 'salon'),
      ],
    );
    final result = change(before, source);
    expect(result.after.entityIds, ['light.manual', 'light.old']);
    expect(result.after.areaBinding!.importedEntityIds, ['light.old']);
    expect(change(result.after, source).hasChanges, isFalse);
  });

  test('HA rename follows accepted name but preserves a manual room label', () {
    final source = snapshot(
      areas: const [HaArea(areaId: 'salon', name: 'Oturma Odası')],
    );
    expect(change(room(), source).after.name, 'Oturma Odası');
    final manual = change(room(name: 'Bizim Oda'), source);
    expect(manual.after.name, 'Bizim Oda');
    expect(manual.after.areaBinding!.sourceName, 'Oturma Odası');
  });

  test(
    'legacy unbound membership remains manual on explicit first binding',
    () {
      const before = DashboardRoom(
        id: 'legacy',
        name: 'My room',
        entityIds: ['light.old'],
      );
      final result = change(
        before,
        snapshot(
          entries: const [
            HaRegistryEntry(entityId: 'light.old', areaId: 'salon'),
            HaRegistryEntry(entityId: 'light.new', areaId: 'salon'),
          ],
        ),
      );
      expect(result.after.entityIds, ['light.old', 'light.new']);
      expect(result.after.name, 'My room');
      expect(result.after.areaBinding!.importedEntityIds, ['light.new']);
    },
  );

  test(
    'another server or area cannot silently replace an existing binding',
    () {
      final other = AreaSyncSnapshot(
        serverUrl: 'http://other.test',
        areas: const [HaArea(areaId: 'salon', name: 'Salon')],
        devices: const [],
        registry: const [],
        entities: const {},
      );
      expect(() => change(room(), other), throwsFormatException);
      expect(
        () => buildRoomAreaSyncChange(
          room: room(),
          snapshot: snapshot(),
          areaId: 'other',
        ),
        throwsFormatException,
      );
    },
  );

  test('new diagnostics, disabled and hidden entries are not auto-added', () {
    final result = change(
      room(),
      snapshot(
        entries: const [
          HaRegistryEntry(entityId: 'sensor.rssi', areaId: 'salon'),
          HaRegistryEntry(entityId: 'sensor.temperature', areaId: 'salon'),
          HaRegistryEntry(
            entityId: 'light.disabled',
            areaId: 'salon',
            disabledBy: 'user',
          ),
          HaRegistryEntry(
            entityId: 'light.hidden',
            areaId: 'salon',
            hiddenBy: 'user',
          ),
        ],
        entities: const {
          'sensor.rssi': HaEntity(entityId: 'sensor.rssi', state: '-80'),
          'sensor.temperature': HaEntity(
            entityId: 'sensor.temperature',
            state: '24',
            attributes: {'device_class': 'temperature'},
          ),
          'light.disabled': HaEntity(entityId: 'light.disabled', state: 'off'),
          'light.hidden': HaEntity(entityId: 'light.hidden', state: 'off'),
        },
      ),
    );
    expect(result.added, ['sensor.temperature']);
  });

  test(
    'duplicate or malformed registry IDs are invalid, never deletion evidence',
    () {
      expect(
        () => snapshot(
          entries: const [
            HaRegistryEntry(entityId: 'light.a'),
            HaRegistryEntry(entityId: 'light.a'),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => snapshot(entries: const [HaRegistryEntry(entityId: '../bad')]),
        throwsFormatException,
      );
      expect(
        () => snapshot(
          areas: const [HaArea(areaId: 'salon', name: '')],
        ),
        throwsFormatException,
      );
    },
  );

  test('5000 entities are stable, deduplicated and idempotent without timing thresholds', () {
    final source = snapshot(
      entries: [
        for (var i = 4999; i >= 0; i--)
          HaRegistryEntry(
            entityId: 'light.item_${i.toString().padLeft(4, '0')}',
            areaId: 'salon',
          ),
      ],
    );
    final result = change(
      const DashboardRoom(id: 'large', name: 'Salon'),
      source,
    );
    expect(result.added, hasLength(5000));
    expect(result.added.toSet(), hasLength(5000));
    expect(result.added.first, 'light.item_0000');
    expect(result.added.last, 'light.item_4999');
    expect(change(result.after, source).after, result.after);
  });
}
