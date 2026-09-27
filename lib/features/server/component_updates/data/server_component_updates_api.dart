import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_component_update_models.dart';

final class ServerComponentUpdatesApi {
  const ServerComponentUpdatesApi(this.api, this.token);

  final LarenorServerApi api;
  final String token;

  Future<ServerComponentUpdateInventory> inventory() async =>
      ServerComponentUpdateInventory.fromJson(
        await api.request('GET', '/admin/component-updates', token: token),
      );

  Future<ServerComponentReleasePreference> putPreference({
    required ServerComponentReleasePreference current,
    required String mode,
    required bool requireUpstreamSignature,
  }) async {
    if (!serverComponentReleasePreferenceModes.contains(mode)) {
      throw const LarenorServerException('invalid_request');
    }
    return ServerComponentReleasePreference.fromJson(
      await api.request(
        'PUT',
        '/admin/component-updates/${current.serviceId}/preference',
        token: token,
        body: {
          'schemaVersion': 1,
          'expectedRevision': current.revision,
          'mode': mode,
          'requireUpstreamSignature': requireUpstreamSignature,
        },
      ),
    );
  }

  Future<ServerComponentUpdateCommand> confirm({
    required ServerInstalledComponentUpdate installed,
    required ServerComponentUpdateReview review,
    required ServerComponentReleasePreference preference,
  }) async => ServerComponentUpdateCommand.fromJson(
    await api.request(
      'POST',
      '/admin/component-updates/installations/'
          '${installed.installationId}/confirm',
      token: token,
      body: {
        'schemaVersion': 1,
        'expectedSourceDigest': installed.sourceDigest,
        'expectedReviewDigest': review.reviewDigest,
        'expectedPreferenceRevision': preference.revision,
        'approvePermissionAdditions': review.addedPermissions.isNotEmpty,
        'approveManualReview': review.blockers.contains(
          'manual_approval_required',
        ),
        'approveRollbackSnapshot': review.rollbackSnapshotRequired,
      },
    ),
  );

  Future<ServerComponentUpdateJob> getJob(String updateId) async =>
      ServerComponentUpdateJob.fromJson(
        await api.request(
          'GET',
          '/admin/component-updates/jobs/$updateId',
          token: token,
        ),
      );

  Future<ServerComponentUpdateJob> cancelJob(
    ServerComponentUpdateJob current,
  ) async => ServerComponentUpdateJob.fromJson(
    await api.request(
      'POST',
      '/admin/component-updates/jobs/${current.updateId}/cancel',
      token: token,
      body: {'schemaVersion': 1, 'expectedRevision': current.revision},
    ),
  );
}
