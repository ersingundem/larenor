import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';

void main() {
  final json = {
    'entity_id': 'light.living_room',
    'state': 'on',
    'attributes': {'friendly_name': 'Living Room Light'},
    'last_changed': '2026-01-01T12:00:00.000Z',
    'last_updated': '2026-01-01T12:00:00.000Z',
  };

  test('fromJson maps snake_case fields', () {
    final entity = HaEntity.fromJson(json);

    expect(entity.entityId, 'light.living_room');
    expect(entity.state, 'on');
    expect(entity.attributes['friendly_name'], 'Living Room Light');
    expect(entity.lastChanged, isNotNull);
  });

  test('domain is derived from the entity id prefix', () {
    expect(HaEntity.fromJson(json).domain, 'light');
  });

  test('friendlyName falls back to entity id when unset', () {
    final withoutName = HaEntity.fromJson({
      'entity_id': 'sensor.temperature',
      'state': '21.5',
    });
    expect(withoutName.friendlyName, 'sensor.temperature');
  });

  test('isOn reflects the "on" state', () {
    expect(HaEntity.fromJson(json).isOn, isTrue);
    expect(HaEntity.fromJson({...json, 'state': 'off'}).isOn, isFalse);
  });

  test('isToggleable is true for controllable domains only', () {
    expect(HaEntity.fromJson(json).isToggleable, isTrue);
    expect(
      HaEntity.fromJson({...json, 'entity_id': 'sensor.temperature'})
          .isToggleable,
      isFalse,
    );
  });
}
