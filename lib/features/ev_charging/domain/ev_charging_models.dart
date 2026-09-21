enum EvCapabilityState { ready, degraded, unavailable }

final class EvChargerCapability {
  const EvChargerCapability({
    required this.id,
    required this.label,
    required this.chargerRevision,
    required this.scheduleRevision,
    required this.tariffRevision,
    required this.powerBudgetRevision,
    required this.currentSoc,
    required this.batteryCapacityWh,
    required this.maxCurrentAmp,
  });
  final String id, label;
  final int chargerRevision, scheduleRevision, tariffRevision;
  final int powerBudgetRevision, currentSoc, batteryCapacityWh, maxCurrentAmp;
}

final class EvChargeCapability {
  const EvChargeCapability({
    required this.coreId,
    required this.homeId,
    required this.state,
    required this.providerKind,
    required this.canPlan,
    required this.canControl,
    required this.reason,
    required this.chargers,
  });
  final String coreId, homeId, providerKind, reason;
  final EvCapabilityState state;
  final bool canPlan, canControl;
  final List<EvChargerCapability> chargers;
}

final class EvChargeSlot {
  const EvChargeSlot({
    required this.start,
    required this.end,
    required this.currentAmp,
    required this.energyWh,
    required this.tariffMicrosPerKwh,
  });
  final DateTime start, end;
  final int currentAmp, energyWh, tariffMicrosPerKwh;
}

final class EvChargePlan {
  const EvChargePlan({
    required this.coreId,
    required this.homeId,
    required this.chargerId,
    required this.accountId,
    required this.sessionFamilyId,
    required this.previewId,
    required this.planHash,
    required this.chargerRevision,
    required this.scheduleRevision,
    required this.requiredWh,
    required this.status,
    required this.slots,
  });
  final String coreId, homeId, chargerId, accountId, sessionFamilyId;
  final String previewId, planHash, status;
  final int chargerRevision, scheduleRevision, requiredWh;
  final List<EvChargeSlot> slots;
}

final class EvChargeReceipt {
  const EvChargeReceipt({
    required this.commandId,
    required this.previewId,
    required this.planHash,
    required this.status,
  });
  final String commandId, previewId, planHash, status;
}

abstract interface class EvChargingGateway {
  Future<EvChargeCapability> capability();
  Future<EvChargePlan> preview({
    required EvChargerCapability charger,
    required String previewId,
    required DateTime departure,
    required int targetSoc,
  });
  Future<EvChargeReceipt> confirm(EvChargePlan plan, String commandId);
  void retire();
}
