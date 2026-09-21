import 'package:flutter/foundation.dart';

enum EnergyPlanAction { charge, discharge, hold }

@immutable
final class EnergyPlanSlot {
  const EnergyPlanSlot({
    required this.index,
    required this.action,
    required this.powerW,
    required this.projectedSocWh,
    required this.reason,
  });
  final int index, powerW, projectedSocWh;
  final EnergyPlanAction action;
  final String reason;
}

@immutable
final class EnergyPrioritySnapshot {
  const EnergyPrioritySnapshot({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.homeRevision,
    required this.accountRevision,
    required this.canControl,
    required this.planId,
    required this.inputDigest,
    required this.batteryId,
    required this.batteryRevision,
    required this.inverterId,
    required this.inverterRevision,
    required this.reservePercent,
    required this.stateOfChargePercent,
    required this.solarEnergyWh,
    required this.consumptionEnergyWh,
    required this.importPriceMicrosPerKwh,
    required this.slots,
  });
  final String coreId, homeId, accountId, sessionFamilyId;
  final int homeRevision, accountRevision;
  final bool canControl;
  final String planId, inputDigest, batteryId;
  final int batteryRevision;
  final String? inverterId;
  final int? inverterRevision;
  final int reservePercent, stateOfChargePercent;
  final int solarEnergyWh, consumptionEnergyWh, importPriceMicrosPerKwh;
  final List<EnergyPlanSlot> slots;

  bool exactFor(EnergyPrioritySnapshot other) =>
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision;
}

@immutable
final class EnergyCommandPreview {
  const EnergyCommandPreview({
    required this.requestId,
    required this.planId,
    required this.inputDigest,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.inverterId,
    required this.inverterRevision,
    required this.batteryId,
    required this.batteryRevision,
    required this.targetPowerW,
    required this.confirmationToken,
  });
  final String requestId, planId, inputDigest, coreId, homeId;
  final String accountId, sessionFamilyId;
  final String inverterId, batteryId, confirmationToken;
  final int inverterRevision, batteryRevision, targetPowerW;
}

@immutable
final class EnergyCommandResult {
  const EnergyCommandResult({
    required this.requestId,
    required this.verified,
    required this.targetPowerW,
    required this.observedPowerW,
  });
  final String requestId;
  final bool verified;
  final int? targetPowerW, observedPowerW;

  bool exactFor(EnergyCommandPreview preview) =>
      requestId == preview.requestId &&
      verified &&
      targetPowerW == preview.targetPowerW &&
      observedPowerW == preview.targetPowerW;

  @override
  bool operator ==(Object other) =>
      other is EnergyCommandResult &&
      requestId == other.requestId &&
      verified == other.verified &&
      targetPowerW == other.targetPowerW &&
      observedPowerW == other.observedPowerW;
  @override
  int get hashCode =>
      Object.hash(requestId, verified, targetPowerW, observedPowerW);
}
