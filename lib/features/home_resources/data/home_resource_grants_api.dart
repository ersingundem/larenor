import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_grants.dart';
import '../domain/home_resource_models.dart';

/// Unwired admin transport. Server checks current authorization on every call.
final class HomeResourceGrantsApi {
  const HomeResourceGrantsApi(
    LarenorServerApi api,
    String token,
    ServerContext context,
  ) : _api = api,
      _token = token,
      _context = context;

  final LarenorServerApi _api;
  final String _token;
  final ServerContext _context;

  String _path(HomeResourceRecord target) {
    if (target.context != _context)
      throw const LarenorServerException('invalid_request');
    return '/admin/home-resources/${_context.coreId}/${_context.homeId}/${target.id}/grants';
  }

  Future<HomeResourceGrants> read(HomeResourceRecord target) async {
    final body = await _api.request('GET', _path(target), token: _token);
    return HomeResourceGrants.fromJson(body, target: target);
  }

  Future<HomeResourceGrants> set(
    HomeResourceGrants snapshot, {
    required String subjectId,
    required HomeResourcePermission permission,
  }) async {
    final path = _path(snapshot.target);
    if (!HomeResourceGrants.isSubjectId(subjectId)) {
      throw const LarenorServerException('invalid_request');
    }
    final previous = snapshot.permissionFor(subjectId);
    if (previous != permission &&
        snapshot.aclRevision == HomeResourceGrants.maximumRevision) {
      throw const LarenorServerException('revision_conflict');
    }
    if (previous == HomeResourcePermission.none &&
        permission != HomeResourcePermission.none &&
        snapshot.grants.length == HomeResourceGrants.maximumGrants) {
      throw const LarenorServerException('invalid_request');
    }
    final body = await _api.request(
      'PUT',
      '$path/$subjectId',
      token: _token,
      body: {
        'expectedAclRevision': snapshot.aclRevision,
        'permissions': permission.toJson(),
      },
    );
    return snapshot.withUpdatedGrant(
      body,
      subjectId: subjectId,
      permission: permission,
    );
  }

  @override
  String toString() => 'HomeResourceGrantsApi';
}
