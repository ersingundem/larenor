import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_grants.dart';
import '../domain/home_resource_models.dart';

/// Unwired admin transport. Server checks current authorization on every call.
final class HomeResourceGrantsApi {
  const HomeResourceGrantsApi(LarenorServerApi api, String token, ServerContext context);
  Future<HomeResourceGrants> read(HomeResourceRecord target) async =>
      throw const LarenorServerException('invalid_response');
  Future<HomeResourceGrants> set(HomeResourceGrants snapshot, {required String subjectId,
      required HomeResourcePermission permission}) async =>
      throw const LarenorServerException('invalid_response');
  @override
  String toString() => 'HomeResourceGrantsApi';
}
