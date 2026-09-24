import '../../data/larenor_server_api.dart';
import '../domain/server_core_backup_models.dart';

final class ServerCoreBackupsApi {
  const ServerCoreBackupsApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;

  Future<CoreBackupPlan> plan(LarenorTransferCancellation cancellation) async =>
      CoreBackupPlan.fromJson(
        await api.request(
          'GET',
          '/admin/backups/plan',
          token: token,
          cancellation: cancellation,
        ),
      );

  Future<CoreBackupExport> export(
    LarenorRequestSecret passphrase,
    LarenorBinaryDestination destination,
    LarenorTransferCancellation cancellation,
  ) async {
    final receipt = await api.exportCoreBackup(
      token: token,
      passphrase: passphrase,
      destination: destination,
      cancellation: cancellation,
    );
    return CoreBackupExport(
      destination: receipt.destination,
      byteLength: receipt.byteLength,
      sha256: receipt.sha256,
      captureGeneration: receipt.captureGeneration,
    );
  }

  Future<CoreBackupCompatibility> preflight(
    CoreBackupManifest manifest,
    LarenorTransferCancellation cancellation,
  ) async => CoreBackupCompatibility.fromJson(
    await api.request(
      'POST',
      '/admin/backups/restore/validate',
      token: token,
      body: {'manifest': manifest.toJson()},
      cancellation: cancellation,
    ),
  );

  @override
  String toString() => 'ServerCoreBackupsApi';
}
