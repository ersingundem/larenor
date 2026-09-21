import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_recovery_models.dart';

class ServerMediaRecoveryApi {
  const ServerMediaRecoveryApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;

  Future<ServerMediaRecoveryStatus> read() async {
    try {
      return ServerMediaRecoveryStatus.fromJson(
        await api.request('GET', '/admin/media/recovery-status', token: token),
      );
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }
}
