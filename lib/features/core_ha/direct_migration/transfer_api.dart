import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';

/// Explicit transfer adapter; its protocol is implemented after runtime RED.
final class CoreHaTransferApi {
  CoreHaTransferApi(this.transport, this.token, this.target, {required this.isCurrent});
  final LarenorServerApi transport;
  final String token;
  final HomeResourceRecord target;
  final bool Function() isCurrent;
  Future<dynamic> preview({required String requestId, required String name,
    required String baseUrl, required String credential, required String entityId}) async => throw UnimplementedError();
}
