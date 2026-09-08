import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/core_ha_models.dart';

final class CoreHaApi {
  CoreHaApi(this.transport, this.token, this.target, {required this.isCurrent});
  final LarenorServerApi transport;
  final String token;
  final HomeResourceRecord target;
  final bool Function() isCurrent;
  void retire() {}
  Future<HomeResourceRecord> resource() async => throw UnimplementedError();
  Future<CoreHaSnapshot> snapshot() async => throw UnimplementedError();
  Future<CoreHaBinding?> binding() async => throw UnimplementedError();
  Future<List<ServerService>> services() async => throw UnimplementedError();
  Future<CoreHaPreview> preview({required ServerService service, required String entityId, required CoreHaBinding? existing}) async => throw UnimplementedError();
  Future<CoreHaBinding> confirm(CoreHaPreview preview) async => throw UnimplementedError();
  Future<void> cancel(CoreHaPreview preview) async => throw UnimplementedError();
}
