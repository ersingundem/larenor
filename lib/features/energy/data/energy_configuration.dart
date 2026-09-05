import '../domain/energy_models.dart';

const energyStatisticLimit = 128;

class EnergyConfiguration {
  EnergyConfiguration(
    List<EnergyMeterDefinition> meters,
    List<EnergyIssue> issues,
  ) : meters = List.unmodifiable(meters),
      issues = List.unmodifiable(issues);
  final List<EnergyMeterDefinition> meters;
  final List<EnergyIssue> issues;
  bool get costsConfigured => meters.any((meter) => meter.role.isCurrency);
}

/// Supports HA 2026.8.3 flat grid preferences and the prior flow_from/flow_to
/// arrays. One statistic is requested once; conflicting roles never form totals.
EnergyConfiguration parseEnergyConfiguration(
  Object? raw, {
  Object? information,
}) {
  final json = energyObject(raw);
  final sources = energyList(json['energy_sources'], 256);
  final devices = energyList(json['device_consumption'] ?? [], 512);
  final costSensors = information == null
      ? <String, dynamic>{}
      : energyObject(energyObject(information)['cost_sensors'] ?? {});
  if (costSensors.length > 512) {
    throw const EnergyException(EnergyFailure.limitExceeded);
  }
  final meters = <String, EnergyMeterDefinition>{};
  final issues = <EnergyIssue>[];
  void add(Object? id, EnergyRole role, {Object? name, Object? included}) {
    if (id == null) return;
    final statisticId = energyStatisticId(id);
    final meter = EnergyMeterDefinition(
      statisticId: statisticId,
      role: role,
      name: energyOptionalName(name),
      includedInStatisticId: included == null
          ? null
          : energyStatisticId(included),
    );
    if (meters.containsKey(meter.key)) {
      issues.add(
        EnergyIssue(
          EnergySource.preferences,
          EnergyFailure.duplicateStatistic,
          statisticId: statisticId,
        ),
      );
      if (meters[meter.key]!.includedInStatisticId !=
          meter.includedInStatisticId) {
        issues.add(
          EnergyIssue(
            EnergySource.preferences,
            EnergyFailure.invalidHierarchy,
            statisticId: statisticId,
          ),
        );
      }
      return;
    }
    meters[meter.key] = meter;
  }

  void grid(Map<String, dynamic> source) {
    final from = source['stat_energy_from'];
    final to = source['stat_energy_to'];
    add(from, EnergyRole.gridImport, name: source['name']);
    add(to, EnergyRole.gridExport, name: source['name']);
    if (from != null) {
      add(
        source['stat_cost'] ?? costSensors[energyStatisticId(from)],
        EnergyRole.gridCost,
        name: source['name'],
      );
    }
    if (to != null) {
      add(
        source['stat_compensation'] ?? costSensors[energyStatisticId(to)],
        EnergyRole.gridCompensation,
        name: source['name'],
      );
    }
  }

  for (final rawSource in sources) {
    final source = energyObject(rawSource);
    switch (source['type']) {
      case 'grid':
        if (source.containsKey('flow_from') || source.containsKey('flow_to')) {
          for (final flow in energyList(source['flow_from'] ?? [], 128)) {
            grid(energyObject(flow));
          }
          for (final flow in energyList(source['flow_to'] ?? [], 128)) {
            grid(energyObject(flow));
          }
          // A mixed legacy/flat object is handled through the same dedup map.
        }
        grid(source);
      case 'solar':
        add(
          source['stat_energy_from'],
          EnergyRole.solarProduction,
          name: source['name'],
        );
      case 'battery':
        add(
          source['stat_energy_from'],
          EnergyRole.batteryDischarge,
          name: source['name'],
        );
        add(
          source['stat_energy_to'],
          EnergyRole.batteryCharge,
          name: source['name'],
        );
      default:
        issues.add(
          const EnergyIssue(
            EnergySource.preferences,
            EnergyFailure.unsupportedSource,
          ),
        );
    }
  }
  for (final rawDevice in devices) {
    final device = energyObject(rawDevice);
    if (device['stat_consumption'] == null) {
      throw const EnergyException(EnergyFailure.invalidResponse);
    }
    add(
      device['stat_consumption'],
      EnergyRole.deviceConsumption,
      name: device['name'],
      included: device['included_in_stat'],
    );
  }
  final byId = <String, List<EnergyMeterDefinition>>{};
  for (final meter in meters.values) {
    byId.putIfAbsent(meter.statisticId, () => []).add(meter);
  }
  if (byId.length > energyStatisticLimit) {
    throw const EnergyException(EnergyFailure.limitExceeded);
  }
  for (final entry in byId.entries) {
    if (entry.value.length > 1) {
      issues.add(
        EnergyIssue(
          EnergySource.preferences,
          EnergyFailure.conflictingStatistic,
          statisticId: entry.key,
        ),
      );
    }
  }
  final parents = {
    for (final meter in meters.values)
      if (meter.role == EnergyRole.deviceConsumption)
        meter.statisticId: meter.includedInStatisticId,
  };
  for (final id in parents.keys) {
    final visited = <String>{id};
    var parent = parents[id];
    while (parent != null) {
      if (!parents.containsKey(parent) || !visited.add(parent)) {
        issues.add(
          EnergyIssue(
            EnergySource.preferences,
            EnergyFailure.invalidHierarchy,
            statisticId: id,
          ),
        );
        break;
      }
      parent = parents[parent];
    }
  }
  final ordered = meters.values.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return EnergyConfiguration(ordered, issues);
}

class EnergyStatisticMetadata {
  const EnergyStatisticMetadata(
    this.statisticId,
    this.name,
    this.hasSum,
    this.unitClass,
    this.statisticsUnit,
  );
  final String statisticId;
  final String? name;
  final bool hasSum;
  final String? unitClass;
  final String? statisticsUnit;
  String? outputUnit(EnergyRole role, String? currency) {
    if (!hasSum) return null;
    if (role.isCurrency) {
      return currency != null &&
              RegExp(r'^[A-Z]{3}$').hasMatch(currency) &&
              unitClass == null &&
              statisticsUnit == currency
          ? currency
          : null;
    }
    // Unit_class was absent in older recorder metadata. An explicit different
    // class is never inferred to be energy merely from a unit label.
    const energyUnits = {
      'mWh',
      'Wh',
      'kWh',
      'MWh',
      'GWh',
      'TWh',
      'J',
      'kJ',
      'MJ',
      'GJ',
      'cal',
      'kcal',
      'Mcal',
      'Gcal',
    };
    return (unitClass == null || unitClass == 'energy') &&
            energyUnits.contains(statisticsUnit)
        ? 'kWh'
        : null;
  }
}

Map<String, EnergyStatisticMetadata> parseEnergyMetadata(
  Object? raw,
  Set<String> requested,
) {
  final rows = energyList(raw, energyStatisticLimit);
  final result = <String, EnergyStatisticMetadata>{};
  for (final row in rows) {
    final value = energyObject(row);
    final id = energyStatisticId(value['statistic_id']);
    if (!requested.contains(id) ||
        result.containsKey(id) ||
        value['has_sum'] is! bool) {
      throw const EnergyException(EnergyFailure.invalidResponse);
    }
    final unit =
        value['statistics_unit_of_measurement'] ?? value['unit_of_measurement'];
    final unitClass = value['unit_class'];
    if ((unit != null && unit is! String) ||
        (unitClass != null && unitClass is! String)) {
      throw const EnergyException(EnergyFailure.invalidResponse);
    }
    result[id] = EnergyStatisticMetadata(
      id,
      energyOptionalName(value['name']),
      value['has_sum'] as bool,
      unitClass as String?,
      unit as String?,
    );
  }
  return Map.unmodifiable(result);
}

Map<String, dynamic> energyObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const EnergyException(EnergyFailure.invalidResponse);
  }
  return value;
}

List<dynamic> energyList(Object? value, int limit) {
  if (value is! List) {
    throw const EnergyException(EnergyFailure.invalidResponse);
  }
  if (value.length > limit) {
    throw const EnergyException(EnergyFailure.limitExceeded);
  }
  return value;
}

String energyStatisticId(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 256 ||
      !RegExp(r'^[a-zA-Z0-9_.:-]+$').hasMatch(value)) {
    throw const EnergyException(EnergyFailure.invalidResponse);
  }
  return value;
}

String? energyOptionalName(Object? value) {
  if (value == null) return null;
  if (value is! String ||
      value.length > 512 ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const EnergyException(EnergyFailure.invalidResponse);
  }
  return value.isEmpty ? null : value;
}
