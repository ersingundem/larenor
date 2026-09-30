import 'package:flutter/foundation.dart';

import '../../data/larenor_server_api.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_power_recovery_models.dart';
import 'server_power_recovery_api.dart';

final class ServerPowerRecoveryController extends ChangeNotifier {
  ServerPowerRecoveryController(this.account) {
    _accountGeneration = account.generation;
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  late int _accountGeneration;
  int _generation = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  PowerRecoveryStatus? value;
  LarenorTransferCancellation? _cancellation;

  bool get _authorized =>
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (_accountGeneration != account.generation || !_authorized) {
      _accountGeneration = account.generation;
      invalidate();
    }
  }

  bool _current(int epoch, int accountEpoch, bool Function() current) =>
      !_disposed &&
      epoch == _generation &&
      account.isCurrent(accountEpoch) &&
      _authorized &&
      current();

  Future<void> _run(
    bool Function() current,
    Future<void> Function(
      ServerPowerRecoveryApi api,
      LarenorTransferCancellation cancellation,
      bool Function() stillCurrent,
    )
    action,
  ) async {
    if (_disposed || busy || !_authorized || !current()) return;
    final epoch = _generation, accountEpoch = account.generation;
    final cancellation = LarenorTransferCancellation();
    _cancellation = cancellation;
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        if (!_current(epoch, accountEpoch, current)) {
          throw const LarenorServerException('cancelled');
        }
        await action(
          ServerPowerRecoveryApi(api, session.accessToken),
          cancellation,
          () => _current(epoch, accountEpoch, current),
        );
      });
    } catch (error) {
      if (_current(epoch, accountEpoch, current)) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (!_disposed && epoch == _generation) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> load({required bool Function() current}) async {
    await _run(current, (api, cancellation, stillCurrent) async {
      final next = await api.status(cancellation);
      if (stillCurrent()) value = next;
    });
  }

  Future<void> configure({
    required String sourceId,
    required String sourceToken,
    required int criticalRuntimeSeconds,
    required int restoreStableSeconds,
    required List<PowerRecoveryTarget> targets,
    required bool Function() current,
  }) async {
    await _run(current, (api, cancellation, stillCurrent) async {
      await api.configure(
        expectedRevision: value?.policy?.revision ?? 0,
        sourceId: sourceId,
        sourceToken: sourceToken,
        criticalRuntimeSeconds: criticalRuntimeSeconds,
        restoreStableSeconds: restoreStableSeconds,
        targets: targets,
        cancellation: cancellation,
      );
      final next = await api.status(cancellation);
      if (stillCurrent()) value = next;
    });
  }

  Future<void> retry({required bool Function() current}) async {
    final run = value?.activeRun;
    if (run == null || run.state != PowerRunState.failed) return;
    await _run(current, (api, cancellation, stillCurrent) async {
      await api.retry(run, cancellation);
      final next = await api.status(cancellation);
      if (stillCurrent()) value = next;
    });
  }

  static bool _reconcilable(PowerRecoveryStep step) =>
      step.state == PowerStepState.uncertain &&
      step.targetId != null &&
      const {'shutdownTarget', 'startTarget'}.contains(step.action);

  bool _sameUncertainStep(PowerRecoveryRun run, PowerRecoveryStep step) {
    final active = value?.activeRun;
    if (active == null ||
        active.runId != run.runId ||
        active.updatedAt != run.updatedAt ||
        active.state != PowerRunState.failed) {
      return false;
    }
    final matches = active.steps.where((item) => item.stepId == step.stepId);
    if (matches.length != 1) return false;
    final current = matches.single;
    return _reconcilable(current) &&
        current.action == step.action &&
        current.targetId == step.targetId;
  }

  Future<void> reconcile({
    required PowerRecoveryStep step,
    required bool Function() current,
  }) async {
    final run = value?.activeRun;
    if (run == null ||
        run.state != PowerRunState.failed ||
        !_reconcilable(step) ||
        !_sameUncertainStep(run, step)) {
      return;
    }
    bool sameRun() => current() && _sameUncertainStep(run, step);
    await _run(sameRun, (api, cancellation, stillCurrent) async {
      final reconciled = await api.reconcile(run, step, cancellation);
      if (reconciled.runId != run.runId) {
        throw const LarenorServerException('invalid_response');
      }
      final next = await api.status(cancellation);
      if (stillCurrent()) value = next;
    });
  }

  void invalidate() {
    _cancellation?.cancel();
    _cancellation = null;
    _generation++;
    busy = false;
    failure = null;
    value = null;
    _emit();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    account.removeListener(_accountChanged);
    _cancellation?.cancel();
    super.dispose();
  }
}
