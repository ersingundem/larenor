import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';

void main() {
  test('resolves automationId from the matching registry entry', () {
    final entities = [
      HaEntity.fromJson({
        'entity_id': 'automation.morning_lights',
        'state': 'on',
        'attributes': {'friendly_name': 'Morning Lights'},
      }),
    ];
    final registry = {
      'automation.morning_lights': HaRegistryEntry.fromJson({
        'entity_id': 'automation.morning_lights',
        'unique_id': 'abc-123',
      }),
    };

    final summaries = buildAutomationSummaries(entities, registry);

    expect(summaries, hasLength(1));
    expect(summaries.first.automationId, 'abc-123');
    expect(summaries.first.isOn, isTrue);
  });

  test('automationId is null when the registry has no entry for it', () {
    final entities = [
      HaEntity.fromJson({
        'entity_id': 'automation.no_registry_entry',
        'state': 'off',
        'attributes': <String, dynamic>{},
      }),
    ];

    final summaries = buildAutomationSummaries(entities, {});

    expect(summaries.first.automationId, isNull);
    expect(summaries.first.isOn, isFalse);
  });

  test('results are sorted by friendly name', () {
    final entities = [
      HaEntity.fromJson({
        'entity_id': 'automation.z_last',
        'state': 'on',
        'attributes': {'friendly_name': 'Z Last'},
      }),
      HaEntity.fromJson({
        'entity_id': 'automation.a_first',
        'state': 'on',
        'attributes': {'friendly_name': 'A First'},
      }),
    ];

    final summaries = buildAutomationSummaries(entities, {});

    expect(summaries.map((s) => s.friendlyName), ['A First', 'Z Last']);
  });
}
