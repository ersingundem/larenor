import '../domain/legacy_remote_models.dart';

abstract interface class LegacyRemoteManagementApi {
  Future<List<LegacyRemoteDevice>> list(LegacyRemoteAuthority authority);

  Future<LegacyRemoteCommandPreview> preview(
    LegacyRemoteAuthority authority, {
    required LegacyRemoteDevice device,
    required LegacyRemoteCommandDefinition command,
    required int repeats,
    required int holdMs,
  });

  Future<LegacyRemoteCommandResult> confirm(
    LegacyRemoteAuthority authority,
    LegacyRemoteCommandPreview preview,
  );

  Future<LegacyRemoteCommandResult> readback(
    LegacyRemoteAuthority authority, {
    required String requestId,
  });
}
