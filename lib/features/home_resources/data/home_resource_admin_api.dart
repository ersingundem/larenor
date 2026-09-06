import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_models.dart';

/// Unwired metadata transport. Server authorization is required for every call.
final class HomeResourceAdminApi {
  const HomeResourceAdminApi(LarenorServerApi api, String token, ServerContext context);
  Future<HomeResourceRecord> create({required HomeResourceKind kind, required String label, required int order}) async =>
      throw const LarenorServerException('invalid_request');
  Future<HomeResourceRecord> update(HomeResourceRecord target, {required String label, required int order}) async =>
      throw const LarenorServerException('invalid_request');
  Future<void> delete(HomeResourceRecord target) async =>
      throw const LarenorServerException('invalid_request');
  @override
  String toString() => 'HomeResourceAdminApi';
}
