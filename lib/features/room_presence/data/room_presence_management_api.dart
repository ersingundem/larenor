import '../domain/room_presence_management_models.dart';

/// Authenticated Core boundary. Sensor identifiers and provider credentials
/// remain inside Core and never enter this interface.
abstract interface class RoomPresenceManagementApi {
  Future<List<RoomPresenceEvidence>> list(
    RoomPresenceClientAuthority authority,
  );

  Future<PresenceCalibrationPreview> previewCalibration(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
    required String expectedDeviceRevision,
    required String expectedModelRevision,
    required String roomId,
    required String expectedRoomRevision,
    required String expectedPolicyRevision,
    required String expectedConsentRevision,
    required String expectedCalibrationRevision,
  });

  Future<PresenceCalibrationReceipt> confirmCalibration(
    RoomPresenceClientAuthority authority,
    PresenceCalibrationPreview preview,
  );

  Future<RoomPresenceEvidence> readback(
    RoomPresenceClientAuthority authority, {
    required String deviceId,
  });
}
