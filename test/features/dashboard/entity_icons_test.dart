import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/dashboard/presentation/tiles/entity_icons.dart';
import 'package:oikos/features/ha_client/data/models/ha_entity.dart';

HaEntity _entity({
  required String entityId,
  String state = 'on',
  Map<String, dynamic> attributes = const {},
}) {
  return HaEntity.fromJson({
    'entity_id': entityId,
    'state': state,
    'attributes': attributes,
  });
}

void main() {
  group('domain-based icons (brand-agnostic)', () {
    test('lock resolves to locked/unlocked variants by state', () {
      expect(
        iconForEntity(_entity(entityId: 'lock.front_door', state: 'locked')),
        CupertinoIcons.lock_fill,
      );
      expect(
        iconForEntity(_entity(entityId: 'lock.front_door', state: 'unlocked')),
        CupertinoIcons.lock_open_fill,
      );
    });

    test('device_tracker (e.g. Keenetic presence) resolves', () {
      expect(
        iconForEntity(_entity(entityId: 'device_tracker.phone')),
        CupertinoIcons.location_fill,
      );
    });

    test('humidifier and siren resolve', () {
      expect(
        iconForEntity(_entity(entityId: 'humidifier.bedroom')),
        CupertinoIcons.drop_fill,
      );
      expect(
        iconForEntity(_entity(entityId: 'siren.alarm')),
        CupertinoIcons.bell_fill,
      );
    });

    test('vacuum, valve, and water_heater resolve', () {
      expect(
        iconForEntity(_entity(entityId: 'vacuum.robot')),
        CupertinoIcons.arrow_2_circlepath,
      );
      expect(
        iconForEntity(_entity(entityId: 'valve.garden')),
        CupertinoIcons.drop,
      );
      expect(
        iconForEntity(_entity(entityId: 'water_heater.tank')),
        CupertinoIcons.flame_fill,
      );
    });

    test('unknown domain falls back to a generic icon', () {
      expect(
        iconForEntity(_entity(entityId: 'totally_new_domain.thing')),
        CupertinoIcons.square_grid_2x2,
      );
    });
  });

  group('sensor device_class icons (e.g. Anker Solix power/battery)', () {
    test('battery', () {
      expect(
        iconForEntity(
          _entity(
            entityId: 'sensor.battery_level',
            attributes: {'device_class': 'battery'},
          ),
        ),
        CupertinoIcons.battery_100,
      );
    });

    test('power/energy/current/voltage all map to a bolt icon', () {
      for (final deviceClass in ['power', 'energy', 'current', 'voltage']) {
        expect(
          iconForEntity(
            _entity(
              entityId: 'sensor.reading',
              attributes: {'device_class': deviceClass},
            ),
          ),
          CupertinoIcons.bolt_fill,
          reason: 'device_class=$deviceClass',
        );
      }
    });

    test('unrecognized device_class falls back to a generic graph icon', () {
      expect(
        iconForEntity(
          _entity(
            entityId: 'sensor.custom',
            attributes: {'device_class': 'some_unknown_class'},
          ),
        ),
        CupertinoIcons.graph_circle,
      );
    });

    test('no device_class at all falls back to a generic graph icon', () {
      expect(
        iconForEntity(_entity(entityId: 'sensor.custom')),
        CupertinoIcons.graph_circle,
      );
    });
  });

  group('binary_sensor device_class icons (e.g. Anker Solix AC socket)', () {
    test('plug/power maps to a bolt icon', () {
      expect(
        iconForEntity(
          _entity(
            entityId: 'binary_sensor.ac_socket',
            attributes: {'device_class': 'plug'},
          ),
        ),
        CupertinoIcons.bolt_fill,
      );
    });

    test('motion/occupancy/presence map to a person icon', () {
      for (final deviceClass in ['motion', 'occupancy', 'presence']) {
        expect(
          iconForEntity(
            _entity(
              entityId: 'binary_sensor.hall',
              attributes: {'device_class': deviceClass},
            ),
          ),
          CupertinoIcons.person_fill,
          reason: 'device_class=$deviceClass',
        );
      }
    });

    test('connectivity maps to a wifi icon', () {
      expect(
        iconForEntity(
          _entity(
            entityId: 'binary_sensor.router_online',
            attributes: {'device_class': 'connectivity'},
          ),
        ),
        CupertinoIcons.wifi,
      );
    });

    test('unrecognized device_class falls back to a generic icon', () {
      expect(
        iconForEntity(_entity(entityId: 'binary_sensor.custom')),
        CupertinoIcons.checkmark_square,
      );
    });
  });
}
