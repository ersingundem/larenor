import '../../data/larenor_server_api.dart';
import '../domain/server_core_backup_models.dart';

final class ServerCoreBackupsApi {
  const ServerCoreBackupsApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;

  Future<CoreBackupPlan> plan() async => CoreBackupPlan.fromJson(
    await api.request('GET', '/admin/backups/plan', token: token),
  );

  @override
  String toString() => 'ServerCoreBackupsApi';
}
