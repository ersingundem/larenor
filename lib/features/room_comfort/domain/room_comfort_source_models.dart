import '../../home_resources/domain/home_resource_models.dart';
import '../../server/services/domain/server_service_models.dart';

final class RoomComfortSetupCatalog {
  const RoomComfortSetupCatalog({
    required this.services,
    required this.rooms,
    required this.areas,
    required this.configuration,
  });

  final List<ServerService> services;
  final List<HomeResourceRecord> rooms, areas;
  final RoomComfortSourceConfiguration? configuration;
}

final class RoomComfortEntityCatalog {
  const RoomComfortEntityCatalog({
    required this.climates,
    required this.covers,
    required this.sensors,
    required this.binarySensors,
    required this.weather,
  });

  final List<String> climates, covers, sensors, binarySensors, weather;
}

final class RoomComfortRoomSource {
  const RoomComfortRoomSource({
    required this.roomId,
    required this.roomRevision,
    required this.areaId,
    required this.areaRevision,
    required this.climateEntityId,
    required this.windowEntityId,
    required this.temperatureEntityId,
    required this.humidityEntityId,
    required this.co2EntityId,
    required this.vocEntityId,
    required this.smokeEntityId,
    required this.occupancyEntityId,
  });

  final String roomId, areaId;
  final int roomRevision, areaRevision;
  final String climateEntityId, windowEntityId, temperatureEntityId;
  final String humidityEntityId, co2EntityId, vocEntityId;
  final String smokeEntityId, occupancyEntityId;

  Map<String, Object?> toJson() => {
    'roomId': roomId,
    'roomRevision': roomRevision,
    'areaId': areaId,
    'areaRevision': areaRevision,
    'climateEntityId': climateEntityId,
    'windowEntityId': windowEntityId,
    'temperatureEntityId': temperatureEntityId,
    'humidityEntityId': humidityEntityId,
    'co2EntityId': co2EntityId,
    'vocEntityId': vocEntityId,
    'smokeEntityId': smokeEntityId,
    'occupancyEntityId': occupancyEntityId,
  };
}

final class RoomComfortSourceConfiguration {
  const RoomComfortSourceConfiguration({
    required this.revision,
    required this.serviceId,
    required this.serviceRevision,
    required this.weatherEntityId,
    required this.aqiEntityId,
    required this.targetTemperatureMilliC,
    required this.temperatureToleranceMilliC,
    required this.humidityHighPermille,
    required this.co2HighPpm,
    required this.vocHighPpb,
    required this.outdoorAqiLimit,
    required this.freezeThresholdMilliC,
    required this.indoorMaxAgeMs,
    required this.outdoorMaxAgeMs,
    required this.occupancyMaxAgeMs,
    required this.previewTtlMs,
    required this.rooms,
  });

  final int revision, serviceRevision;
  final String serviceId, weatherEntityId, aqiEntityId;
  final int targetTemperatureMilliC, temperatureToleranceMilliC;
  final int humidityHighPermille, co2HighPpm, vocHighPpb, outdoorAqiLimit;
  final int freezeThresholdMilliC, indoorMaxAgeMs, outdoorMaxAgeMs;
  final int occupancyMaxAgeMs, previewTtlMs;
  final List<RoomComfortRoomSource> rooms;
}
