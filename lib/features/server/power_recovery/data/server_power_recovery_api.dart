import '../../data/larenor_server_api.dart';
import '../domain/server_power_recovery_models.dart';

final class ServerPowerRecoveryApi {
  const ServerPowerRecoveryApi(this.api, this.token);

  final LarenorServerApi api;
  final String token;

  Future<PowerRecoveryStatus> status(
    LarenorTransferCancellation cancellation,
  ) async => PowerRecoveryStatus.fromJson(
    await api.request(
      'GET',
      '/admin/power-recovery/status',
      token: token,
      cancellation: cancellation,
    ),
  );

  Future<void> configure({
    required int expectedRevision,
    required String sourceId,
    required String sourceToken,
    required int criticalRuntimeSeconds,
    required int restoreStableSeconds,
    required List<PowerRecoveryTarget> targets,
    required LarenorTransferCancellation cancellation,
  }) async {
    await api.request(
      'PUT',
      '/admin/power-recovery/policy',
      token: token,
      body: {
        'contractVersion': 1,
        'expectedRevision': expectedRevision,
        'sourceId': sourceId,
        'sourceToken': sourceToken,
        'criticalRuntimeSeconds': criticalRuntimeSeconds,
        'restoreStableSeconds': restoreStableSeconds,
        'targets': targets.map((item) => item.toJson()).toList(),
      },
      cancellation: cancellation,
    );
  }

  Future<PowerRecoveryRun> retry(
    PowerRecoveryRun run,
    LarenorTransferCancellation cancellation,
  ) async => PowerRecoveryRun.fromJson(
    await api.request(
      'POST',
      '/admin/power-recovery/runs/${run.runId}/retry',
      token: token,
      body: {
        'contractVersion': 1,
        'expectedUpdatedAt': run.updatedAt.millisecondsSinceEpoch ~/ 1000,
      },
      cancellation: cancellation,
    ),
  );

  Future<PowerRecoveryRun> reconcile(
    PowerRecoveryRun run,
    PowerRecoveryStep step,
    LarenorTransferCancellation cancellation,
  ) async => PowerRecoveryRun.fromJson(
    await api.request(
      'POST',
      '/admin/power-recovery/runs/${run.runId}/steps/${step.stepId}/reconcile',
      token: token,
      body: {
        'contractVersion': 1,
        'expectedUpdatedAt': run.updatedAt.millisecondsSinceEpoch ~/ 1000,
      },
      cancellation: cancellation,
    ),
  );
}
