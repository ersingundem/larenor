import 'package:flutter/foundation.dart';

@immutable
final class IrrigationBudgetAuthority {
  const IrrigationBudgetAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.policyId,
    required this.routeId,
    required this.homeRevision,
    required this.accountRevision,
    required this.policyRevision,
    required this.budgetRevision,
    required this.clientSessionRevision,
    required this.routeRevision,
  });

  final String coreId, homeId, accountId, sessionFamilyId, policyId, routeId;
  final int homeRevision, accountRevision, policyRevision, budgetRevision;
  final int clientSessionRevision, routeRevision;

  bool get isBounded =>
      [
        coreId,
        homeId,
        accountId,
        sessionFamilyId,
        policyId,
        routeId,
      ].every((value) => value.isNotEmpty) &&
      [
        homeRevision,
        accountRevision,
        policyRevision,
        budgetRevision,
      ].every((value) => value > 0) &&
      clientSessionRevision >= 0 &&
      routeRevision >= 0;
}

@immutable
final class IrrigationZoneBudget {
  const IrrigationZoneBudget({
    required this.zoneId,
    required this.zoneRevision,
    required this.areaName,
    required this.plantName,
    required this.moisturePermille,
    required this.soilReadingRevision,
    required this.status,
    required this.reason,
    required this.durationSeconds,
    required this.estimatedWaterMl,
  });

  final String zoneId, areaName, plantName, status, reason;
  final int zoneRevision, moisturePermille, soilReadingRevision;
  final int durationSeconds, estimatedWaterMl;
}

@immutable
final class IrrigationBudgetSnapshot {
  const IrrigationBudgetSnapshot({
    required this.authority,
    required this.planId,
    required this.generatedAtMs,
    required this.forecastStatus,
    required this.rainMilliMm,
    required this.dailyLimitMl,
    required this.usedMl,
    required this.plannedMl,
    required this.estimatedCostMicros,
    required this.controlCapability,
    required this.commandEndpointAvailable,
    required this.zones,
  });

  final IrrigationBudgetAuthority authority;
  final String planId, forecastStatus, controlCapability;
  final int generatedAtMs, rainMilliMm, dailyLimitMl, usedMl, plannedMl;
  final int estimatedCostMicros;
  final bool commandEndpointAvailable;
  final List<IrrigationZoneBudget> zones;

  bool get isVerified =>
      authority.isBounded &&
      zones.isNotEmpty &&
      const {'available', 'stale'}.contains(forecastStatus) &&
      const {'read_only', 'manual_required'}.contains(controlCapability) &&
      !commandEndpointAvailable;
}
