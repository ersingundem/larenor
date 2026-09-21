import '../domain/mesh_center_models.dart';

abstract interface class MeshCenterManagementApi {
  Future<MeshCenterSnapshot> load(MeshClientAuthority authority);

  Future<MeshFirmwareUpdatePreview> preview(
    MeshClientAuthority authority, {
    required MeshCenterSnapshot snapshot,
    required MeshClientDevice device,
    required MeshFirmwareOffer firmware,
  });

  Future<MeshFirmwareUpdateResult> confirm(
    MeshClientAuthority authority,
    MeshFirmwareUpdatePreview preview,
  );

  Future<MeshFirmwareUpdateResult> readback(
    MeshClientAuthority authority, {
    required String requestId,
  });
}
