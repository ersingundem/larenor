import '../../home_resources/domain/home_resource_models.dart';
import '../../server/services/domain/server_service_models.dart';

final class RoomPresenceSourceConfiguration {
  const RoomPresenceSourceConfiguration({
    required this.revision,
    required this.serviceId,
    required this.serviceRevision,
    required this.entityId,
    required this.entityName,
    required this.consentActive,
    required this.maxSignalAgeMs,
    required this.rooms,
  });

  final int revision, serviceRevision, maxSignalAgeMs;
  final String serviceId, entityId, entityName;
  final bool consentActive;
  final List<RoomPresenceConfiguredRoom> rooms;
}

final class RoomPresenceConfiguredRoom {
  const RoomPresenceConfiguredRoom({
    required this.roomId,
    required this.roomRevision,
    required this.roomLabel,
  });
  final String roomId, roomLabel;
  final int roomRevision;
}

final class RoomPresenceEntityCandidate {
  const RoomPresenceEntityCandidate({
    required this.candidateId,
    required this.entityId,
    required this.name,
  });
  final String candidateId, entityId, name;
}

final class RoomPresenceSetupCatalog {
  const RoomPresenceSetupCatalog({
    required this.services,
    required this.rooms,
    required this.configuration,
  });
  final List<ServerService> services;
  final List<HomeResourceRecord> rooms;
  final RoomPresenceSourceConfiguration? configuration;
}
