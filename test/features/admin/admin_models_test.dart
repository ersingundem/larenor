import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/admin/data/models/config_entry.dart';
import 'package:oikos/features/admin/data/models/flow_step.dart';
import 'package:oikos/features/admin/data/models/ha_area.dart';
import 'package:oikos/features/admin/data/models/ha_device.dart';
import 'package:oikos/features/admin/data/models/ha_registry_entry.dart';

void main() {
  test('ConfigEntry.fromJson maps snake_case fields', () {
    final entry = ConfigEntry.fromJson({
      'entry_id': 'abc123',
      'domain': 'hue',
      'title': 'Philips Hue',
      'source': 'user',
      'state': 'loaded',
      'disabled_by': null,
    });

    expect(entry.entryId, 'abc123');
    expect(entry.domain, 'hue');
    expect(entry.state, 'loaded');
    expect(entry.disabledBy, isNull);
  });

  test('HaDevice.displayName prefers name_by_user', () {
    final withUserName = HaDevice.fromJson({
      'id': 'dev1',
      'name': 'Original Name',
      'name_by_user': 'Living Room Hub',
    });
    expect(withUserName.displayName, 'Living Room Hub');

    final withoutUserName = HaDevice.fromJson({
      'id': 'dev1',
      'name': 'Original Name',
    });
    expect(withoutUserName.displayName, 'Original Name');

    final withNeither = HaDevice.fromJson({'id': 'dev1'});
    expect(withNeither.displayName, 'dev1');
  });

  test('HaArea.fromJson maps area_id', () {
    final area = HaArea.fromJson({
      'area_id': 'living_room',
      'name': 'Living Room',
    });
    expect(area.areaId, 'living_room');
    expect(area.name, 'Living Room');
  });

  test('HaRegistryEntry.displayName falls back through name chain', () {
    final withName = HaRegistryEntry.fromJson({
      'entity_id': 'light.kitchen',
      'name': 'Custom Name',
      'original_name': 'Kitchen Light',
    });
    expect(withName.displayName, 'Custom Name');

    final withOriginalOnly = HaRegistryEntry.fromJson({
      'entity_id': 'light.kitchen',
      'original_name': 'Kitchen Light',
    });
    expect(withOriginalOnly.displayName, 'Kitchen Light');

    final withNeither = HaRegistryEntry.fromJson({
      'entity_id': 'light.kitchen',
    });
    expect(withNeither.displayName, 'light.kitchen');
  });

  test('FlowStep.fromJson parses a form step with nested data_schema', () {
    final step = FlowStep.fromJson({
      'flow_id': 'flow1',
      'type': 'form',
      'step_id': 'user',
      'last_step': false,
      'data_schema': [
        {'name': 'host', 'required': true, 'type': 'string'},
      ],
    });

    expect(step.flowId, 'flow1');
    expect(step.type, 'form');
    expect(step.stepId, 'user');
    expect(step.lastStep, isFalse);
    expect(step.dataSchema, hasLength(1));
    expect(step.dataSchema.first.name, 'host');
  });

  test('FlowStep.fromJson handles a step with no data_schema', () {
    final step = FlowStep.fromJson({
      'type': 'create_entry',
      'title': 'Philips Hue',
    });
    expect(step.type, 'create_entry');
    expect(step.dataSchema, isEmpty);
  });
}
