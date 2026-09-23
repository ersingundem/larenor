import '../../data/larenor_server_api.dart';
import '../domain/server_core_backup_models.dart';

final class ServerCoreBackupsApi {
  const ServerCoreBackupsApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;

  Future<CoreBackupPlan> plan() async => CoreBackupPlan.fromJson(
    await api.request('GET', '/admin/backups/plan', token: token),
  );

  Future<CoreBackupExport> export(String passphrase) async => CoreBackupExport(
    await api.exportCoreBackup(token: token, passphrase: passphrase),
  );

  Future<CoreBackupCompatibility> preflight(
    CoreBackupManifest manifest,
  ) async => CoreBackupCompatibility.fromJson(
    await api.request(
      'POST',
      '/admin/backups/restore/validate',
      token: token,
      body: {'manifest': manifest.toJson()},
    ),
  );

  @override
  String toString() => 'ServerCoreBackupsApi';
}
