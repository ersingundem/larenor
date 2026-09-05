enum EnergyRange { today, last7Days }

enum EnergyRole {
  gridImport,
  gridExport,
  solarProduction,
  batteryCharge,
  batteryDischarge,
  deviceConsumption,
  gridCost,
  gridCompensation;

  bool get isCurrency => this == gridCost || this == gridCompensation;
}

enum EnergySource {
  configuration,
  preferences,
  information,
  metadata,
  daily,
  hourly,
}

enum EnergyFailure {
  authentication,
  permission,
  transport,
  timeout,
  invalidResponse,
  invalidTimezone,
  unsupportedUnit,
  missingMetadata,
  duplicateStatistic,
  conflictingStatistic,
  invalidHierarchy,
  unsupportedSource,
  limitExceeded,
}

enum EnergyCoverageIssue {
  missingDay,
  missingBaseline,
  hourlyGap,
  invalidData,
  boundaryLimited,
  ongoing,
}

class EnergyIssue {
  const EnergyIssue(this.source, this.failure, {this.statisticId});
  final EnergySource source;
  final EnergyFailure failure;
  final String? statisticId;
}

class EnergyDayWindow {
  const EnergyDayWindow({
    required this.localDate,
    required this.start,
    required this.endExclusive,
  });
  final String localDate;
  final DateTime start;
  final DateTime endExclusive;
  bool contains(DateTime value) =>
      !value.isBefore(start) && value.isBefore(endExclusive);
}

class EnergyPeriod {
  EnergyPeriod({
    required this.range,
    required this.timeZone,
    required List<EnergyDayWindow> days,
    required this.observedAt,
  }) : days = List.unmodifiable(days);
  final EnergyRange range;
  final String timeZone;
  final List<EnergyDayWindow> days;
  final DateTime observedAt;
  DateTime get start => days.first.start;
  DateTime get endExclusive => days.last.endExclusive;
  // Core expands period:day through the midnight after the containing day.
  DateTime get dailyRequestEnd =>
      endExclusive.subtract(const Duration(milliseconds: 1));
  bool get isOngoing => observedAt.isBefore(endExclusive);
  bool get boundaryLimited => days.any(
    (day) =>
        day.start.millisecondsSinceEpoch % Duration.millisecondsPerHour != 0 ||
        day.endExclusive.millisecondsSinceEpoch %
                Duration.millisecondsPerHour !=
            0,
  );
}

class EnergyMeterDefinition {
  const EnergyMeterDefinition({
    required this.statisticId,
    required this.role,
    this.name,
    this.includedInStatisticId,
  });
  final String statisticId;
  final EnergyRole role;
  final String? name;
  final String? includedInStatisticId;
  String get key => '${role.name}:$statisticId';
}

class EnergyDayReading {
  EnergyDayReading({
    required this.window,
    required this.reportedValue,
    required this.expectedHours,
    required this.receivedHours,
    required this.hasBaseline,
    Set<EnergyCoverageIssue> issues = const {},
  }) : issues = Set.unmodifiable(issues);
  final EnergyDayWindow window;

  /// HA-reported daily change, already converted by Recorder. Never a raw-state delta.
  final double? reportedValue;
  final int expectedHours;
  final int receivedHours;
  final bool hasBaseline;
  final Set<EnergyCoverageIssue> issues;
  bool get isPartial => issues.isNotEmpty;
}

class EnergyMeterReading {
  EnergyMeterReading({
    required this.definition,
    required this.name,
    required this.unit,
    required List<EnergyDayReading> daily,
    List<EnergyIssue> issues = const [],
  }) : daily = List.unmodifiable(daily),
       issues = List.unmodifiable(issues);
  final EnergyMeterDefinition definition;
  String get statisticId => definition.statisticId;
  EnergyRole get role => definition.role;
  String? get includedInStatisticId => definition.includedInStatisticId;
  final String name;

  /// kWh or the validated HA currency code; null means unit evidence is missing.
  final String? unit;
  final List<EnergyDayReading> daily;
  final List<EnergyIssue> issues;
  double? get reportedTotal {
    final values = daily.map((day) => day.reportedValue).whereType<double>();
    if (values.isEmpty || unit == null) return null;
    final sum = values.fold(0.0, (sum, value) => sum + value);
    return sum.isFinite ? sum : null;
  }

  bool get isPartial => issues.isNotEmpty || daily.any((day) => day.isPartial);
  Set<EnergyCoverageIssue> get coverageIssues => {
    for (final day in daily) ...day.issues,
  };
}

class EnergySnapshot {
  EnergySnapshot({
    required this.energyConfigured,
    required this.readAt,
    this.period,
    List<EnergyMeterReading> meters = const [],
    List<EnergyIssue> issues = const [],
    this.costsConfigured = false,
  }) : meters = List.unmodifiable(meters),
       issues = List.unmodifiable(issues);

  /// null: preference read failed; false: HA explicitly reported not configured.
  final bool? energyConfigured;
  final bool costsConfigured;

  /// A failed preference/info read may conceal generated cost sensors.
  bool get costsConfigurationKnown =>
      energyConfigured == true &&
      !issues.any(
        (issue) =>
            issue.source == EnergySource.preferences ||
            issue.source == EnergySource.information,
      );
  final EnergyPeriod? period;
  final DateTime readAt;
  final List<EnergyMeterReading> meters;
  final List<EnergyIssue> issues;
  bool get isPartial =>
      issues.isNotEmpty || meters.any((meter) => meter.isPartial);
}

class EnergyViewState {
  const EnergyViewState({
    this.snapshot,
    this.isRefreshing = false,
    this.failure,
    this.connectionConfigured = true,
  });
  final EnergySnapshot? snapshot;
  final bool isRefreshing;
  final EnergyFailure? failure;
  final bool connectionConfigured;
}

class EnergyException implements Exception {
  const EnergyException(this.failure);
  final EnergyFailure failure;
  @override
  String toString() => 'Energy data could not be read';
}
