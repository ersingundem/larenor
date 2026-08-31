import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/models/automation_summary.dart';
import 'package:larenor/features/admin/presentation/automations_screen.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';

void main() {
  const automation = AutomationSummary(
    entityId: 'automation.morning',
    friendlyName: 'Morning routine',
    isOn: true,
    automationId: 'abc123',
  );

  test('not editable when automationId is null', () {
    const notEditable = AutomationSummary(
      entityId: 'automation.custom',
      friendlyName: 'Custom',
      isOn: true,
      automationId: null,
    );
    expect(
      automationSubtitle(notEditable, null),
      'Config not editable from here',
    );
  });

  test('never triggered when the attribute is absent', () {
    final entity = HaEntity.fromJson({
      'entity_id': 'automation.morning',
      'state': 'on',
      'attributes': <String, dynamic>{},
    });
    expect(automationSubtitle(automation, entity), 'Never triggered');
  });

  test('never triggered when there is no live entity at all', () {
    expect(automationSubtitle(automation, null), 'Never triggered');
  });

  test('formats a valid last_triggered timestamp', () {
    final entity = HaEntity.fromJson({
      'entity_id': 'automation.morning',
      'state': 'on',
      'attributes': {'last_triggered': '2026-01-01T08:00:00+00:00'},
    });
    expect(
      automationSubtitle(automation, entity),
      startsWith('Last triggered: '),
    );
  });

  test('falls back to the raw string for an unparsable timestamp', () {
    final entity = HaEntity.fromJson({
      'entity_id': 'automation.morning',
      'state': 'on',
      'attributes': {'last_triggered': 'not-a-date'},
    });
    expect(
      automationSubtitle(automation, entity),
      'Last triggered: not-a-date',
    );
  });
}
