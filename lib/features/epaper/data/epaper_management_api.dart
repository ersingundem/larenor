import '../domain/epaper_management_models.dart';

/// Core-facing boundary. Implementations authenticate with the current Larenor
/// session; no device token or bridge secret crosses the presentation layer.
abstract interface class EpaperManagementApi {
  Future<EpaperDeviceStatus> map(
    EpaperClientAuthority authority,
    EpaperDeviceMappingDraft draft,
  );

  Future<List<EpaperDeviceStatus>> list(EpaperClientAuthority authority);

  Future<EpaperCommandPreview> preview(
    EpaperClientAuthority authority, {
    required String deviceId,
    required String expectedDeviceRevision,
    required EpaperManagementAction action,
  });

  Future<EpaperCommandReceipt> confirm(
    EpaperClientAuthority authority,
    EpaperCommandPreview preview,
  );

  Future<void> cancel(
    EpaperClientAuthority authority,
    EpaperCommandPreview preview,
  );

  Future<EpaperDeviceStatus> readback(
    EpaperClientAuthority authority, {
    required String deviceId,
  });
}
