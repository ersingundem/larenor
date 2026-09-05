import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy/domain/maintenance_models.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';

HaEntity maintenanceEntity(
  String id,
  String state, [
  Map<String, dynamic> attributes = const {},
]) => HaEntity(
  entityId: id,
  state: state,
  attributes: attributes,
  lastUpdated: DateTime.utc(2001),
);

void main() {
  test('only recognized maintenance evidence is included; unknown and old timestamps are not offline', () {
    final entities = [
      maintenanceEntity('binary_sensor.problem', 'on', {
        'device_class': 'problem',
      }),
      maintenanceEntity('binary_sensor.battery', 'on', {
        'device_class': 'battery',
      }),
      maintenanceEntity('update.router', 'on'),
      maintenanceEntity('light.offline', 'unavailable'),
      maintenanceEntity('sensor.unknown', 'unknown'),
      maintenanceEntity('light.old', 'on'),
      maintenanceEntity('binary_sensor.motion', 'on', {
        'device_class': 'motion',
      }),
      maintenanceEntity('binary_sensor.no_problem', 'off', {
        'device_class': 'problem',
      }),
    ];
    final snapshot = buildMaintenanceSnapshot({
      for (final item in entities) item.entityId: item,
    }, scope: MaintenanceScope.all);
    expect(snapshot.checkedEntities, 8);
    expect(snapshot.items.map((item) => item.entityId), [
      'binary_sensor.problem',
      'light.offline',
      'binary_sensor.battery',
      'update.router',
    ]);
    expect(snapshot.items.map((item) => item.kinds.single), [
      MaintenanceKind.problem,
      MaintenanceKind.unavailable,
      MaintenanceKind.lowBattery,
      MaintenanceKind.updateAvailable,
    ]);
  });
  test(
    'battery percentage requires correct unit and finite bounded numeric state',
    () {
      final values = [
        '0',
        '20',
        '20.1',
        '100',
        '-1',
        '101',
        'NaN',
        'Infinity',
        'unknown',
      ];
      final entities = {
        for (var i = 0; i < values.length; i++)
          'sensor.battery_$i': maintenanceEntity(
            'sensor.battery_$i',
            values[i],
            {'device_class': 'battery', 'unit_of_measurement': '%'},
          ),
      };
      entities['sensor.voltage'] = maintenanceEntity('sensor.voltage', '2', {
        'device_class': 'battery',
        'unit_of_measurement': 'V',
      });
      entities['sensor.untyped'] = maintenanceEntity('sensor.untyped', '2', {
        'unit_of_measurement': '%',
      });
      final snapshot = buildMaintenanceSnapshot(
        entities,
        scope: MaintenanceScope.all,
      );
      expect(snapshot.items.map((item) => item.batteryPercent), [0, 20]);
    },
  );
  test('selected scope never includes other rooms; all explicitly includes them and ordering is stable at 5000 entities', () {
    final entities = {
      for (var i = 0; i < 5000; i++)
        'sensor.fixture_$i': maintenanceEntity(
          'sensor.fixture_$i',
          i.isEven ? 'unavailable' : 'unknown',
        ),
    };
    final selected = buildMaintenanceSnapshot(
      entities,
      scope: MaintenanceScope.selected,
      selectedIds: {'sensor.fixture_20', 'sensor.fixture_10', 'sensor.missing'},
    );
    expect(selected.checkedEntities, 2);
    expect(selected.items.map((item) => item.entityId), [
      'sensor.fixture_10',
      'sensor.fixture_20',
    ]);
    final all = buildMaintenanceSnapshot(entities, scope: MaintenanceScope.all);
    final reverse = buildMaintenanceSnapshot(
      Map.fromEntries(entities.entries.toList().reversed),
      scope: MaintenanceScope.all,
    );
    expect(all.checkedEntities, 5000);
    expect(all.items, hasLength(2500));
    expect(
      all.items.map((item) => item.entityId),
      reverse.items.map((item) => item.entityId),
    );
  });
}
