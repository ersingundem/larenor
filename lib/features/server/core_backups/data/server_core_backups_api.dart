import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_core_backup_models.dart';

final class ServerCoreBackupsApi {
  ServerCoreBackupsApi(this.api, this.token, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;
  final LarenorServerApi api;
  final String token;
  final String Function() _requestId;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

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

  Future<RecoveryDrillSchedule> drillSchedule(
    LarenorTransferCancellation cancellation,
  ) async => RecoveryDrillSchedule.fromJson(
    (await api.request(
      'GET',
      '/admin/backups/drill-schedule',
      token: token,
      cancellation: cancellation,
    ))?['schedule'],
  );

  Future<List<RecoveryDrill>> drills(
    LarenorTransferCancellation cancellation,
  ) async {
    final response = serverObject(
      await api.request(
        'GET',
        '/admin/backups/drills',
        token: token,
        cancellation: cancellation,
      ),
    );
    if (response.length != 2 ||
        !response.keys.every(const {'drills', 'nextBefore'}.contains) ||
        response['drills'] is! List ||
        (response['drills'] as List).length > 20 ||
        response['nextBefore'] != null && response['nextBefore'] is! int) {
      throw const LarenorServerException('invalid_response');
    }
    return List.unmodifiable(
      (response['drills'] as List).map(RecoveryDrill.fromJson),
    );
  }

  Future<RecoveryDrill> runDrill(
    LarenorTransferCancellation cancellation,
  ) async => RecoveryDrill.fromJson(
    (await api.request(
      'POST',
      '/admin/backups/drills',
      token: token,
      body: {
        'contractVersion': 1,
        'requestId': _requestId(),
        'mode': 'isolated_full_restore',
        'deadlineSeconds': 3600,
      },
      cancellation: cancellation,
    ))?['drill'],
  );

  Future<RecoveryDrillSchedule> updateDrillSchedule(
    RecoveryDrillSchedule schedule,
    bool enabled,
    LarenorTransferCancellation cancellation,
  ) async => RecoveryDrillSchedule.fromJson(
    (await api.request(
      'PUT',
      '/admin/backups/drill-schedule',
      token: token,
      body: {'expectedRevision': schedule.revision, 'enabled': enabled},
      cancellation: cancellation,
    ))?['schedule'],
  );

  Future<RecoveryDrill> cancelDrill(
    RecoveryDrill drill,
    LarenorTransferCancellation cancellation,
  ) async => RecoveryDrill.fromJson(
    (await api.request(
      'POST',
      '/admin/backups/drills/${drill.id}/cancel',
      token: token,
      body: {'expectedRevision': drill.revision},
      cancellation: cancellation,
    ))?['drill'],
  );

  Future<ImmutableBackupTarget?> immutableTarget(
    LarenorTransferCancellation cancellation,
  ) async {
    final response = serverObject(
      await api.request(
        'GET',
        '/admin/backups/immutable-target',
        token: token,
        cancellation: cancellation,
      ),
    );
    if (response.length != 1 || !response.containsKey('target')) {
      throw const LarenorServerException('invalid_response');
    }
    return response['target'] == null
        ? null
        : ImmutableBackupTarget.fromJson(response['target']);
  }

  Future<ImmutableRestorePoints?> immutableRestorePoints(
    bool configured,
    LarenorTransferCancellation cancellation,
  ) async => configured
      ? ImmutableRestorePoints.fromJson(
          await api.request(
            'GET',
            '/admin/backups/immutable-target/restore-points',
            token: token,
            cancellation: cancellation,
          ),
        )
      : null;

  Future<ImmutableBackupTarget> configureImmutableTarget({
    required int expectedRevision,
    required String endpoint,
    required String targetId,
    required int retentionDays,
    required int quotaBytes,
    required String writeToken,
    required String recoveryToken,
    required String backupPassphrase,
    required LarenorTransferCancellation cancellation,
  }) async => ImmutableBackupTarget.fromJson(
    (await api.request(
      'PUT',
      '/admin/backups/immutable-target',
      token: token,
      body: {
        'contractVersion': 1,
        'expectedRevision': expectedRevision,
        'endpoint': endpoint,
        'targetId': targetId,
        'retentionDays': retentionDays,
        'quotaBytes': quotaBytes,
        'writeToken': writeToken,
        'recoveryToken': recoveryToken,
        'backupPassphrase': backupPassphrase,
      },
      cancellation: cancellation,
    ))?['target'],
  );

  @override
  String toString() => 'ServerCoreBackupsApi';
}
