import 'package:flutter/foundation.dart';

@immutable
final class IrrigationServiceOption {
  const IrrigationServiceOption({
    required this.id,
    required this.revision,
    required this.name,
  });
  final String id, name;
  final int revision;
}

@immutable
final class IrrigationRoomOption {
  const IrrigationRoomOption({
    required this.id,
    required this.revision,
    required this.label,
  });
  final String id, label;
  final int revision;
}

@immutable
final class IrrigationZoneSourceSettings {
  const IrrigationZoneSourceSettings({
    required this.roomId,
    required this.roomRevision,
    required this.valveEntityId,
    required this.soilMoistureEntityId,
    required this.plantName,
    required this.flowMlPerMinute,
    required this.maxDurationSeconds,
    required this.zoneId,
    required this.zoneRevision,
  });
  final String roomId, valveEntityId, soilMoistureEntityId, plantName, zoneId;
  final int roomRevision, flowMlPerMinute, maxDurationSeconds, zoneRevision;
}

@immutable
final class IrrigationSourceSettings {
  const IrrigationSourceSettings({
    required this.revision,
    required this.serviceId,
    required this.serviceRevision,
    required this.weatherEntityId,
    required this.leakEntityId,
    required this.dailyWaterEntityId,
    required this.targetMoisturePermille,
    required this.soilMaxAgeMs,
    required this.safetyMaxAgeMs,
    required this.forecastMaxAgeMs,
    required this.rainDeferralMilliMm,
    required this.freezeThresholdMilliC,
    required this.windLimitMilliMps,
    required this.previewTtlMs,
    required this.dailyLimitMl,
    required this.priceMicrosPerLiter,
    required this.zones,
  });
  final String serviceId, weatherEntityId, leakEntityId, dailyWaterEntityId;
  final int revision, serviceRevision, targetMoisturePermille;
  final int soilMaxAgeMs, safetyMaxAgeMs, forecastMaxAgeMs;
  final int rainDeferralMilliMm, freezeThresholdMilliC, windLimitMilliMps;
  final int previewTtlMs, dailyLimitMl, priceMicrosPerLiter;
  final List<IrrigationZoneSourceSettings> zones;
}

@immutable
final class IrrigationControllerSettings {
  const IrrigationControllerSettings({
    required this.revision,
    required this.sourceRevision,
    required this.stationIndexes,
  });
  final int revision, sourceRevision;
  final Map<String, int> stationIndexes;
}

@immutable
final class IrrigationSetupCatalog {
  const IrrigationSetupCatalog({
    required this.services,
    required this.rooms,
    required this.source,
    required this.controller,
  });
  final List<IrrigationServiceOption> services;
  final List<IrrigationRoomOption> rooms;
  final IrrigationSourceSettings? source;
  final IrrigationControllerSettings? controller;
}
