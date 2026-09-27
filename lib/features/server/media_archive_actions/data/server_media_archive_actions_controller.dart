import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_archive_action_models.dart';
import 'server_media_archive_actions_api.dart';

final class ServerMediaArchiveActionsController extends ChangeNotifier {
  ServerMediaArchiveActionsController(
    this.account, {
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
  }) : _accountGeneration = account.generation {
    archiveActionId(installationId);
    archiveActionInteger(installationRevision, min: 1);
    archiveActionInteger(snapshotRevision, min: 1);
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final String installationId;
  final int installationRevision, snapshotRevision;
  final int _accountGeneration;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  bool requiresRefresh = false;
  String? failure;
  ServerMediaArchiveSnapshot? snapshot;
  ServerMediaArchivePreview? preview;

  bool get _authorized =>
      account.isCurrent(_accountGeneration) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true &&
      account.session?.user.mustChangePassword == false;

  bool get canConfirm => !busy && !requiresRefresh && preview != null;

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  bool _routeCurrent(bool Function() current) {
    try {
      return current();
    } catch (_) {
      return false;
    }
  }

  void invalidate() {
    _epoch++;
    busy = false;
    requiresRefresh = false;
    failure = null;
    snapshot = null;
    preview = null;
    if (!_disposed) notifyListeners();
  }

  Future<bool> _run({
    required bool Function() current,
    required Future<void> Function(
      ServerMediaArchiveActionsApi api,
      bool Function() valid,
    )
    action,
    bool effectful = false,
  }) async {
    if (_disposed || busy || !_authorized || !_routeCurrent(current)) {
      return false;
    }
    final epoch = _epoch;
    bool valid() =>
        !_disposed && epoch == _epoch && _authorized && _routeCurrent(current);
    busy = true;
    failure = null;
    notifyListeners();
    try {
      await account.withSession((raw, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(
          ServerMediaArchiveActionsApi(raw, session.accessToken),
          valid,
        );
      });
      return valid();
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        if (effectful &&
            {
              'connection_failed',
              'timeout',
              'server_error',
              'invalid_response',
              'media_archive_action_authority_changed',
              'media_archive_action_evidence_changed',
              'media_archive_action_policy_changed',
              'media_archive_action_job_changed',
              'media_archive_action_cleanup_already_confirmed',
            }.contains(failure)) {
          requiresRefresh = true;
          preview = null;
        }
      }
      return false;
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        if (!valid()) {
          failure = null;
          preview = null;
        }
        notifyListeners();
      }
    }
  }

  Future<void> load({required bool Function() current}) async {
    await _run(
      current: current,
      action: (api, valid) async {
        final result = await api.snapshot(
          installationId: installationId,
          installationRevision: installationRevision,
          snapshotRevision: snapshotRevision,
        );
        if (valid()) {
          snapshot = result;
          preview = null;
          requiresRefresh = false;
        }
      },
    );
  }

  Future<void> updateQuota({
    required int sharedQuotaBytes,
    required bool Function() current,
  }) async {
    final before = snapshot;
    if (before == null || sharedQuotaBytes < before.policy.reservedBytes) {
      return;
    }
    await _run(
      current: current,
      action: (api, valid) async {
        final result = await api.updatePolicy(
          previous: before.policy,
          sharedQuotaBytes: sharedQuotaBytes,
        );
        if (valid()) {
          snapshot = before.withPolicy(result);
          preview = null;
        }
      },
      effectful: true,
    );
  }

  Future<void> previewCandidate(
    ServerMediaArchiveCandidate candidate, {
    required bool Function() current,
  }) async {
    final before = snapshot;
    if (before == null || requiresRefresh) return;
    await _run(
      current: current,
      action: (api, valid) async {
        final result =
            candidate.actionType == ServerMediaArchiveActionType.optimize
            ? await api.previewOptimize(snapshot: before, candidate: candidate)
            : await api.previewCleanupCandidate(
                snapshot: before,
                candidate: candidate,
              );
        if (valid()) preview = result;
      },
    );
  }

  Future<void> previewCleanupJob(
    ServerMediaArchiveJob sourceJob, {
    required bool Function() current,
  }) async {
    final before = snapshot;
    if (before == null || requiresRefresh || !sourceJob.cleanupAvailable) {
      return;
    }
    await _run(
      current: current,
      action: (api, valid) async {
        final result = await api.previewCleanupJob(
          snapshot: before,
          sourceJob: sourceJob,
        );
        if (valid()) preview = result;
      },
    );
  }

  void dismissPreview() {
    if (busy) return;
    preview = null;
    failure = null;
    notifyListeners();
  }

  Future<void> confirmPreview({required bool Function() current}) async {
    final before = preview;
    if (before == null || !canConfirm) return;
    await _run(
      current: current,
      action: (api, valid) async {
        final result = await api.confirm(before);
        if (!valid()) return;
        final refreshed = await _refreshed(api);
        final recorded = refreshed.jobs
            .where((item) => item.jobId == result.jobId)
            .firstOrNull;
        if (recorded == null || recorded.revision < result.revision) {
          throw const LarenorServerException('invalid_response');
        }
        if (valid()) {
          snapshot = refreshed;
          preview = null;
        }
      },
      effectful: true,
    );
  }

  Future<void> refreshJob(
    ServerMediaArchiveJob job, {
    required bool Function() current,
  }) => _jobAction(job, 'read', current);

  Future<void> cancelJob(
    ServerMediaArchiveJob job, {
    required bool Function() current,
  }) => _jobAction(job, 'cancel', current);

  Future<void> reconcileJob(
    ServerMediaArchiveJob job, {
    required bool Function() current,
  }) => _jobAction(job, 'reconcile', current);

  Future<void> _jobAction(
    ServerMediaArchiveJob job,
    String action,
    bool Function() current,
  ) async {
    final known = snapshot?.jobs
        .where((item) => item.jobId == job.jobId)
        .firstOrNull;
    if (known == null || known.revision != job.revision || requiresRefresh) {
      return;
    }
    await _run(
      current: current,
      action: (api, valid) async {
        final result = switch (action) {
          'read' => await api.readJob(job),
          'cancel' => await api.cancelJob(job),
          'reconcile' => await api.reconcileJob(job),
          _ => throw const LarenorServerException('invalid_response'),
        };
        if (!valid()) return;
        final refreshed = await _refreshed(api);
        final recorded = refreshed.jobs
            .where((item) => item.jobId == result.jobId)
            .firstOrNull;
        if (recorded == null || recorded.revision < result.revision) {
          throw const LarenorServerException('invalid_response');
        }
        if (valid()) snapshot = refreshed;
      },
      effectful: action != 'read',
    );
  }

  Future<ServerMediaArchiveSnapshot> _refreshed(
    ServerMediaArchiveActionsApi api,
  ) => api.snapshot(
    installationId: installationId,
    installationRevision: installationRevision,
    snapshotRevision: snapshotRevision,
  );

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
