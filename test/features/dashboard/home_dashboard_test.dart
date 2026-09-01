import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/data/models/ha_device.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/dashboard/domain/home_domains.dart';
import 'package:larenor/features/dashboard/providers/home_dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';

HaEntity entity(
  String id, {
  String state = 'on',
  Map<String, dynamic> attributes = const {},
}) => HaEntity(entityId: id, state: state, attributes: attributes);

void main() {
  group('isHomeEntity', () {
    test('keeps controllable domains', () {
      expect(isHomeEntity(entity('light.kitchen')), isTrue);
      expect(isHomeEntity(entity('lock.front_door')), isTrue);
      expect(isHomeEntity(entity('media_player.tv')), isTrue);
    });

    test('drops domains that are never accessories', () {
      expect(isHomeEntity(entity('automation.morning')), isFalse);
      expect(isHomeEntity(entity('update.firmware')), isFalse);
      expect(isHomeEntity(entity('person.ersin')), isFalse);
    });

    test('keeps only sensors with a device class worth showing', () {
      expect(
        isHomeEntity(
          entity(
            'sensor.hallway',
            attributes: const {'device_class': 'temperature'},
          ),
        ),
        isTrue,
      );
      // The diagnostic noise a real HA instance is full of.
      expect(
        isHomeEntity(
          entity(
            'sensor.wifi',
            attributes: const {'device_class': 'signal_strength'},
          ),
        ),
        isFalse,
      );
      expect(isHomeEntity(entity('sensor.uptime')), isFalse);
    });
  });

  group('homeCategoryForEntity', () {
    test('maps domains to the filter chips', () {
      expect(
        homeCategoryForEntity(entity('light.kitchen')),
        HomeCategory.lights,
      );
      expect(
        homeCategoryForEntity(entity('climate.living')),
        HomeCategory.climate,
      );
      expect(
        homeCategoryForEntity(entity('lock.front')),
        HomeCategory.security,
      );
      expect(
        homeCategoryForEntity(entity('media_player.tv')),
        HomeCategory.media,
      );
    });

    test('routes sensors by device class', () {
      expect(
        homeCategoryForEntity(
          entity('sensor.a', attributes: const {'device_class': 'humidity'}),
        ),
        HomeCategory.climate,
      );
      expect(
        homeCategoryForEntity(
          entity(
            'binary_sensor.b',
            attributes: const {'device_class': 'motion'},
          ),
        ),
        HomeCategory.security,
      );
    });
  });

  group('resolveEntityAreaId', () {
    final registry = {
      'light.direct': const HaRegistryEntry(
        entityId: 'light.direct',
        areaId: 'kitchen',
        deviceId: 'dev1',
      ),
      'light.via_device': const HaRegistryEntry(
        entityId: 'light.via_device',
        deviceId: 'dev1',
      ),
      'light.orphan': const HaRegistryEntry(entityId: 'light.orphan'),
    };
    final devices = {'dev1': const HaDevice(id: 'dev1', areaId: 'lounge')};

    test('prefers the entity\'s own area over its device\'s', () {
      expect(resolveEntityAreaId('light.direct', registry, devices), 'kitchen');
    });

    test('falls back to the device area', () {
      expect(
        resolveEntityAreaId('light.via_device', registry, devices),
        'lounge',
      );
    });

    test('returns null with no area anywhere, or no registry entry', () {
      expect(resolveEntityAreaId('light.orphan', registry, devices), isNull);
      expect(resolveEntityAreaId('light.unknown', registry, devices), isNull);
    });
  });

  group('buildHomeDashboard', () {
    final areas = [
      const HaArea(areaId: 'kitchen', name: 'Kitchen'),
      const HaArea(areaId: 'lounge', name: 'Lounge'),
    ];

    test('groups entities into rooms and sorts rooms by name', () {
      final data = buildHomeDashboard(
        entities: [entity('light.b'), entity('switch.a')],
        areas: areas,
        registry: const [
          HaRegistryEntry(entityId: 'light.b', areaId: 'lounge'),
          HaRegistryEntry(entityId: 'switch.a', areaId: 'kitchen'),
        ],
        devices: const [],
        favoriteEntityIds: const [],
        hiddenEntityIds: const [],
      );

      expect(data.rooms.map((r) => r.area.name), ['Kitchen', 'Lounge']);
      expect(data.rooms.first.entities.single.entityId, 'switch.a');
      expect(data.unassigned, isEmpty);
    });

    test('puts entities with no resolvable area under unassigned', () {
      final data = buildHomeDashboard(
        entities: [entity('light.nowhere')],
        areas: areas,
        registry: const [],
        devices: const [],
        favoriteEntityIds: const [],
        hiddenEntityIds: const [],
      );

      expect(data.rooms, isEmpty);
      expect(data.unassigned.single.entityId, 'light.nowhere');
    });

    test('an empty registry (non-admin token) still shows every entity', () {
      final data = buildHomeDashboard(
        entities: [entity('light.a'), entity('switch.b')],
        areas: const [],
        registry: const [],
        devices: const [],
        favoriteEntityIds: const [],
        hiddenEntityIds: const [],
      );

      expect(data.unassigned, hasLength(2));
      expect(data.isEmpty, isFalse);
    });

    test('hidden entities disappear from rooms and favourites alike', () {
      final data = buildHomeDashboard(
        entities: [entity('light.a'), entity('light.b')],
        areas: areas,
        registry: const [
          HaRegistryEntry(entityId: 'light.a', areaId: 'kitchen'),
          HaRegistryEntry(entityId: 'light.b', areaId: 'kitchen'),
        ],
        devices: const [],
        favoriteEntityIds: const ['light.a'],
        hiddenEntityIds: const ['light.a'],
      );

      expect(data.rooms.single.entities.single.entityId, 'light.b');
      expect(data.favorites, isEmpty);
    });

    test('favourites keep the order they were starred in', () {
      final data = buildHomeDashboard(
        entities: [entity('light.a'), entity('light.b'), entity('light.c')],
        areas: const [],
        registry: const [],
        devices: const [],
        favoriteEntityIds: const ['light.c', 'light.a'],
        hiddenEntityIds: const [],
      );

      expect(data.favorites.map((e) => e.entityId), ['light.c', 'light.a']);
    });

    test('counts only lights that are on', () {
      final data = buildHomeDashboard(
        entities: [
          entity('light.a'),
          entity('light.b', state: 'off'),
          entity('switch.c'),
        ],
        areas: const [],
        registry: const [],
        devices: const [],
        favoriteEntityIds: const [],
        hiddenEntityIds: const [],
      );

      expect(data.lightsOn, 1);
    });

    test('entities pointing at a deleted area fall back to unassigned', () {
      final data = buildHomeDashboard(
        entities: [entity('light.a')],
        areas: areas,
        registry: const [
          HaRegistryEntry(entityId: 'light.a', areaId: 'demolished'),
        ],
        devices: const [],
        favoriteEntityIds: const [],
        hiddenEntityIds: const [],
      );

      expect(data.rooms, isEmpty);
      expect(data.unassigned.single.entityId, 'light.a');
    });
  });
}
