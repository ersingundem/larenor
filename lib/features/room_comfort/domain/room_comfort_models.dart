enum ComfortPlanStatus { planned, skipped, blocked }

enum ComfortReason {
  airRefresh,
  temperatureLow,
  temperatureHigh,
  comfortable,
  manualOverride,
  sensorStale,
  smokeDetected,
  freezeRisk,
  rainWindowBlock,
  outdoorAirUnsafe,
}

enum ComfortHvacMode { off, heat, cool, ventilate }

enum ComfortWindowState { closed, open }

enum ComfortOccupancy { occupied, unoccupied, stale }

final class RoomComfortPlan {
  const RoomComfortPlan({
    required this.coreId,
    required this.homeId,
    required this.planId,
    required this.policyId,
    required this.homeRevision,
    required this.policyRevision,
    required this.accountRevision,
    required this.sessionFamilyId,
    required this.generatedAt,
    required this.rooms,
  });

  final String coreId, homeId, planId, policyId, sessionFamilyId;
  final int homeRevision, policyRevision, accountRevision;
  final DateTime generatedAt;
  final List<RoomComfortPlanItem> rooms;
}

final class RoomComfortPlanItem {
  const RoomComfortPlanItem({
    required this.roomId,
    required this.roomRevision,
    required this.areaId,
    required this.areaRevision,
    required this.status,
    required this.reason,
    required this.hvacMode,
    required this.windowState,
    required this.occupancy,
  });

  final String roomId, areaId;
  final int roomRevision, areaRevision;
  final ComfortPlanStatus status;
  final ComfortReason reason;
  final ComfortHvacMode hvacMode;
  final ComfortWindowState windowState;
  final ComfortOccupancy occupancy;
}

abstract interface class RoomComfortGateway {
  Future<RoomComfortPlan> loadPlan();
  void retire();
}
