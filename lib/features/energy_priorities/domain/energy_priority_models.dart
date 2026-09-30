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
    this.startsAt,
  });
  final int index, powerW, projectedSocWh;
  final EnergyPlanAction action;
  final String reason;
  final DateTime? startsAt;
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
    required this.canAdminister,
    required this.canControl,
    required this.canCharge,
    required this.canDischarge,
    required this.canSetReserve,
    required this.planId,
    required this.inputDigest,
    required this.batteryId,
    required this.batteryRevision,
    required this.batteryProviderRevision,
    required this.inverterId,
    required this.inverterRevision,
    required this.reservePercent,
    required this.reserveRevision,
    required this.capacityWh,
    required this.stateOfChargePercent,
    required this.solarEnergyWh,
    required this.consumptionEnergyWh,
    required this.importPriceMicrosPerKwh,
    required this.slots,
    this.meterCapturedAt,
    this.batteryCapturedAt,
    this.forecastGeneratedAt,
    this.slotDuration = const Duration(minutes: 15),
  });
  final String coreId, homeId, accountId, sessionFamilyId;
  final int homeRevision, accountRevision;
  final bool canAdminister;
  final bool canControl;
  final bool canCharge, canDischarge, canSetReserve;
  final String planId, inputDigest, batteryId;
  final int batteryRevision, batteryProviderRevision;
  final String? inverterId;
  final int? inverterRevision;
  final int reservePercent, stateOfChargePercent;
  final int reserveRevision, capacityWh;
  final int solarEnergyWh, consumptionEnergyWh, importPriceMicrosPerKwh;
  final List<EnergyPlanSlot> slots;
  final DateTime? meterCapturedAt, batteryCapturedAt, forecastGeneratedAt;
  final Duration slotDuration;

  EnergyPlanSlot? actionableAt(DateTime now) {
    final instant = now.toUtc();
    if (!slots.any((slot) => slot.startsAt != null)) {
      for (final slot in slots) {
        if (slot.action != EnergyPlanAction.hold) return slot;
      }
      return null;
    }
    for (final slot in slots) {
      final start = slot.startsAt;
      if (slot.action != EnergyPlanAction.hold &&
          start != null &&
          !instant.isBefore(start) &&
          instant.isBefore(start.add(slotDuration))) {
        return slot;
      }
    }
    return null;
  }

  bool exactFor(EnergyPrioritySnapshot other) =>
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamilyId == other.sessionFamilyId &&
      homeRevision == other.homeRevision &&
      accountRevision == other.accountRevision;

  bool supports(EnergyPlanSlot slot) => switch (slot.action) {
    EnergyPlanAction.charge => canCharge,
    EnergyPlanAction.discharge => canDischarge,
    EnergyPlanAction.hold => false,
  };
}

@immutable
final class EnergyReserveSource {
  const EnergyReserveSource({
    required this.serviceId,
    required this.serviceRevision,
    required this.name,
    required this.bindingRevision,
    required this.boundModel,
  });

  final String serviceId, name;
  final int serviceRevision, bindingRevision;
  final String? boundModel;
}

enum EnergyReserveBacktestStatus {
  noSampleBelowReserve,
  sampleBelowReserve,
  uncertain,
}

enum EnergyReserveHistoryCoverage { complete, partial, missing }

@immutable
final class EnergyReserveBacktestSlot {
  const EnergyReserveBacktestSlot({
    required this.startsAt,
    required this.endsAt,
    required this.observedSocPercent,
    required this.forecastRecorded,
    required this.status,
  });

  final DateTime startsAt, endsAt;
  final double? observedSocPercent;
  final bool forecastRecorded;
  final String status;
}

@immutable
final class EnergyReserveBacktest {
  const EnergyReserveBacktest({
    required this.analysisDigest,
    required this.historyDigest,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.homeRevision,
    required this.accountRevision,
    required this.serviceId,
    required this.serviceRevision,
    required this.batteryId,
    required this.batteryRevision,
    required this.batteryProviderRevision,
    required this.reserveRevision,
    required this.reservePercent,
    required this.capacityWh,
    required this.capturedAt,
    required this.startsAt,
    required this.endsAt,
    required this.sampleCount,
    required this.missingSampleCount,
    required this.belowReserveSampleCount,
    required this.forecastRecordCount,
    required this.minimumObservedSocPercent,
    required this.observedStatus,
    required this.sampleCoverage,
    required this.forecastCoverage,
    required this.manualPreference,
    required this.historicalCapacityCoverage,
    required this.historicalReservePolicyCoverage,
    required this.uncertaintyReasons,
    required this.slots,
  });

  final String analysisDigest, historyDigest;
  final String coreId, homeId, accountId, sessionFamilyId;
  final int homeRevision, accountRevision;
  final String serviceId, batteryId;
  final int serviceRevision, batteryRevision, batteryProviderRevision;
  final int reserveRevision, reservePercent, capacityWh;
  final DateTime capturedAt, startsAt, endsAt;
  final int sampleCount, missingSampleCount, belowReserveSampleCount;
  final int forecastRecordCount;
  final double? minimumObservedSocPercent;
  final EnergyReserveBacktestStatus observedStatus;
  final EnergyReserveHistoryCoverage sampleCoverage, forecastCoverage;
  final String manualPreference;
  final String historicalCapacityCoverage, historicalReservePolicyCoverage;
  final List<String> uncertaintyReasons;
  final List<EnergyReserveBacktestSlot> slots;

  bool exactFor(EnergyPrioritySnapshot snapshot) =>
      coreId == snapshot.coreId &&
      homeId == snapshot.homeId &&
      accountId == snapshot.accountId &&
      sessionFamilyId == snapshot.sessionFamilyId &&
      homeRevision == snapshot.homeRevision &&
      accountRevision == snapshot.accountRevision &&
      batteryId == snapshot.batteryId &&
      batteryProviderRevision == snapshot.batteryProviderRevision &&
      reserveRevision == snapshot.reserveRevision &&
      reservePercent == snapshot.reservePercent &&
      capacityWh == snapshot.capacityWh;
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

@immutable
final class EnergyReservePreview {
  const EnergyReservePreview({
    required this.requestId,
    required this.inputDigest,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.inverterId,
    required this.inverterRevision,
    required this.batteryId,
    required this.batteryRevision,
    required this.batteryProviderRevision,
    required this.targetReservePercent,
    required this.confirmationToken,
  });
  final String requestId, inputDigest, coreId, homeId;
  final String accountId, sessionFamilyId, inverterId, batteryId;
  final String confirmationToken;
  final int inverterRevision, batteryRevision, batteryProviderRevision;
  final int targetReservePercent;
}

@immutable
final class EnergyReserveResult {
  const EnergyReserveResult({
    required this.requestId,
    required this.confirmed,
    required this.targetReservePercent,
    required this.observedReservePercent,
    required this.bindingRevision,
  });
  final String requestId;
  final bool confirmed;
  final int targetReservePercent, bindingRevision;
  final int? observedReservePercent;

  bool exactFor(EnergyReservePreview preview) =>
      requestId == preview.requestId &&
      confirmed &&
      targetReservePercent == preview.targetReservePercent &&
      observedReservePercent == preview.targetReservePercent;

  @override
  bool operator ==(Object other) =>
      other is EnergyReserveResult &&
      requestId == other.requestId &&
      confirmed == other.confirmed &&
      targetReservePercent == other.targetReservePercent &&
      observedReservePercent == other.observedReservePercent &&
      bindingRevision == other.bindingRevision;

  @override
  int get hashCode => Object.hash(
    requestId,
    confirmed,
    targetReservePercent,
    observedReservePercent,
    bindingRevision,
  );
}
