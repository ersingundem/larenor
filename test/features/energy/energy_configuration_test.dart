import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy/data/energy_configuration.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';

import 'energy_fixture.dart';

void main() {
  test('flat and legacy grids preserve import/export roles and deduplicate identical meters', () {
    final value = parseEnergyConfiguration(
      energyPreferences(
        sources: [
          {
            'type': 'grid',
            'stat_energy_from': 'sensor.grid',
            'stat_energy_to': 'sensor.export',
            'stat_cost': 'sensor.cost',
          },
          {
            'type': 'grid',
            'flow_from': [
              {'stat_energy_from': 'sensor.grid'},
            ],
            'flow_to': [
              {'stat_energy_to': 'sensor.legacy_export'},
            ],
          },
          {'type': 'solar', 'stat_energy_from': 'sensor.solar'},
          {
            'type': 'battery',
            'stat_energy_from': 'sensor.discharge',
            'stat_energy_to': 'sensor.charge',
          },
        ],
      ),
    );
    expect(
      value.meters.where((meter) => meter.statisticId == 'sensor.grid'),
      hasLength(1),
    );
    expect(
      value.meters
          .singleWhere((meter) => meter.statisticId == 'sensor.charge')
          .role,
      EnergyRole.batteryCharge,
    );
    expect(
      value.meters
          .singleWhere((meter) => meter.statisticId == 'sensor.discharge')
          .role,
      EnergyRole.batteryDischarge,
    );
    expect(value.costsConfigured, isTrue);
    expect(value.issues.single.failure, EnergyFailure.duplicateStatistic);
  });
  test('generated costs are linked only by HA information, never an arbitrary tariff multiplication', () {
    final value = parseEnergyConfiguration(
      energyPreferences(
        sources: [
          {
            'type': 'grid',
            'stat_energy_from': 'sensor.grid',
            'number_energy_price': 999,
          },
        ],
      ),
      information: {
        'cost_sensors': {'sensor.grid': 'sensor.generated_cost'},
      },
    );
    expect(
      value.meters.singleWhere((meter) => meter.role.isCurrency).statisticId,
      'sensor.generated_cost',
    );
    final noGenerated = parseEnergyConfiguration(
      energyPreferences(
        sources: [
          {
            'type': 'grid',
            'stat_energy_from': 'sensor.grid',
            'number_energy_price': 999,
          },
        ],
      ),
    );
    expect(noGenerated.costsConfigured, isFalse);
  });
  test('device hierarchy remains independent and overlap/cycles are explicitly invalid', () {
    final value = parseEnergyConfiguration(
      energyPreferences(
        devices: [
          {'stat_consumption': 'sensor.parent'},
          {
            'stat_consumption': 'sensor.child',
            'included_in_stat': 'sensor.parent',
          },
          {'stat_consumption': 'sensor.grid'},
          {
            'stat_consumption': 'sensor.cycle',
            'included_in_stat': 'sensor.cycle',
          },
        ],
      ),
    );
    expect(
      value.meters
          .singleWhere((meter) => meter.statisticId == 'sensor.child')
          .includedInStatisticId,
      'sensor.parent',
    );
    expect(
      value.issues.any(
        (issue) =>
            issue.statisticId == 'sensor.grid' &&
            issue.failure == EnergyFailure.conflictingStatistic,
      ),
      isTrue,
    );
    expect(
      value.issues.any(
        (issue) =>
            issue.statisticId == 'sensor.cycle' &&
            issue.failure == EnergyFailure.invalidHierarchy,
      ),
      isTrue,
    );
  });
  for (final unit in ['Wh', 'kWh', 'MWh']) {
    test('$unit metadata requests server conversion to kWh', () {
      final value = parseEnergyMetadata(
        [energyMetadata('sensor.grid', unit: unit)],
        {'sensor.grid'},
      );
      expect(
        value['sensor.grid']!.outputUnit(EnergyRole.gridImport, null),
        'kWh',
      );
    });
  }
  test('unsupported units/classes and mean-only statistics cannot supply energy totals', () {
    for (final metadata in [
      energyMetadata('sensor.grid', unit: 'W', unitClass: 'power'),
      energyMetadata('sensor.grid', unit: 'kWh', unitClass: 'power'),
      energyMetadata('sensor.grid', hasSum: false),
    ]) {
      expect(
        parseEnergyMetadata(
          [metadata],
          {'sensor.grid'},
        )['sensor.grid']!.outputUnit(EnergyRole.gridImport, null),
        isNull,
      );
    }
  });
  test('currency must exactly match configured HA currency and cumulative metadata', () {
    final value = parseEnergyMetadata(
      [energyMetadata('sensor.cost', unit: 'TRY', unitClass: null)],
      {'sensor.cost'},
    )['sensor.cost']!;
    expect(value.outputUnit(EnergyRole.gridCost, 'TRY'), 'TRY');
    expect(value.outputUnit(EnergyRole.gridCost, 'USD'), isNull);
    expect(value.outputUnit(EnergyRole.gridCost, null), isNull);
  });
  test(
    'duplicate metadata, invalid IDs and unbounded configuration are rejected',
    () {
      expect(
        () => parseEnergyMetadata(
          [energyMetadata('sensor.grid'), energyMetadata('sensor.grid')],
          {'sensor.grid'},
        ),
        throwsA(isA<EnergyException>()),
      );
      expect(
        () => parseEnergyConfiguration(
          energyPreferences(
            devices: [
              {'stat_consumption': '../../secret'},
            ],
          ),
        ),
        throwsA(isA<EnergyException>()),
      );
      expect(
        () => parseEnergyConfiguration(
          energyPreferences(
            devices: [
              for (var i = 0; i < 129; i++)
                {'stat_consumption': 'sensor.item_$i'},
            ],
          ),
        ),
        throwsA(isA<EnergyException>()),
      );
    },
  );
}
