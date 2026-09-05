import '../../../l10n/generated/app_localizations.dart';
import '../../health/data/integration_health.dart';
import '../../health/presentation/health_labels.dart';
import '../domain/energy_models.dart';
import '../domain/maintenance_models.dart';

String energyRoleLabel(AppLocalizations l10n, EnergyRole role) =>
    switch (role) {
      EnergyRole.gridImport => l10n.energyGridImport,
      EnergyRole.gridExport => l10n.energyGridExport,
      EnergyRole.solarProduction => l10n.energySolar,
      EnergyRole.batteryCharge => l10n.energyBatteryCharge,
      EnergyRole.batteryDischarge => l10n.energyBatteryDischarge,
      EnergyRole.deviceConsumption => l10n.energyDevice,
      EnergyRole.gridCost => l10n.energyCost,
      EnergyRole.gridCompensation => l10n.energyCompensation,
    };

String energyFailureLabel(AppLocalizations l10n, EnergyFailure failure) =>
    switch (failure) {
      EnergyFailure.authentication => healthFailureLabel(
        l10n,
        HealthFailure.authentication,
      ),
      EnergyFailure.permission => healthFailureLabel(
        l10n,
        HealthFailure.permission,
      ),
      EnergyFailure.transport => healthFailureLabel(
        l10n,
        HealthFailure.transport,
      ),
      EnergyFailure.timeout => healthFailureLabel(l10n, HealthFailure.timeout),
      EnergyFailure.invalidTimezone ||
      EnergyFailure.invalidHierarchy ||
      EnergyFailure.duplicateStatistic ||
      EnergyFailure.conflictingStatistic => l10n.energyConfigurationIssue,
      EnergyFailure.unsupportedUnit ||
      EnergyFailure.missingMetadata => l10n.energyUnitIssue,
      _ => l10n.energySourceIssue,
    };

String maintenanceKindLabel(AppLocalizations l10n, MaintenanceKind kind) =>
    switch (kind) {
      MaintenanceKind.lowBattery => l10n.maintenanceLowBattery,
      MaintenanceKind.problem => l10n.maintenanceProblem,
      MaintenanceKind.unavailable => l10n.maintenanceUnavailable,
      MaintenanceKind.updateAvailable => l10n.maintenanceUpdate,
    };

List<String> energyCoverageLabels(
  AppLocalizations l10n,
  Set<EnergyCoverageIssue> issues,
) => [
  if (issues.contains(EnergyCoverageIssue.missingBaseline)) l10n.energyBaseline,
  if (issues.contains(EnergyCoverageIssue.missingDay) ||
      issues.contains(EnergyCoverageIssue.hourlyGap) ||
      issues.contains(EnergyCoverageIssue.invalidData))
    l10n.energyGap,
  if (issues.contains(EnergyCoverageIssue.boundaryLimited)) l10n.energyBoundary,
  if (issues.contains(EnergyCoverageIssue.ongoing)) l10n.energyOngoing,
];
