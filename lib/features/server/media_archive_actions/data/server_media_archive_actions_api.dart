import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_archive_action_models.dart';

final class ServerMediaArchiveActionsApi {
  ServerMediaArchiveActionsApi(
    this.api,
    this.token, {
    String Function()? requestId,
  }) : _requestId = requestId ?? _randomId;

  static const root = '/admin/media/archive-actions';
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

  Never _invalid() => throw const LarenorServerException('invalid_response');

  String _request() => archiveActionId(_requestId());

  Map<String, dynamic> _response(Object? value, String requestId, String key) {
    final map = archiveActionObject(value, {'requestId', key});
    if (map['requestId'] != requestId) _invalid();
    return map;
  }

  Future<ServerMediaArchiveSnapshot> snapshot({
    required String installationId,
    required int installationRevision,
    required int snapshotRevision,
  }) async {
    archiveActionId(installationId);
    archiveActionInteger(installationRevision, min: 1);
    archiveActionInteger(snapshotRevision, min: 1);
    final requestId = _request();
    final map = _response(
      await api.request(
        'POST',
        '$root/snapshot',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'installationId': installationId,
          'expectedInstallationRevision': installationRevision,
          'expectedSnapshotRevision': snapshotRevision,
        },
      ),
      requestId,
      'snapshot',
    );
    final result = ServerMediaArchiveSnapshot.fromJson(map['snapshot']);
    if (result.authority.installationId != installationId ||
        result.authority.installationRevision != installationRevision ||
        result.authority.snapshotRevision != snapshotRevision) {
      _invalid();
    }
    return result;
  }

  Future<ServerMediaArchivePolicy> updatePolicy({
    required ServerMediaArchivePolicy previous,
    required int sharedQuotaBytes,
  }) async {
    archiveActionInteger(
      sharedQuotaBytes,
      min: 256 * 1024 * 1024,
      max: 10 * 1024 * 1024 * 1024 * 1024,
    );
    final requestId = _request();
    final map = _response(
      await api.request(
        'POST',
        '$root/policy',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'expectedRevision': previous.revision,
          'sharedQuotaBytes': sharedQuotaBytes,
        },
      ),
      requestId,
      'policy',
    );
    final result = ServerMediaArchivePolicy.fromJson(map['policy']);
    if (result.revision <= previous.revision ||
        result.sharedQuotaBytes != sharedQuotaBytes) {
      _invalid();
    }
    return result;
  }

  Future<ServerMediaArchivePreview> previewOptimize({
    required ServerMediaArchiveSnapshot snapshot,
    required ServerMediaArchiveCandidate candidate,
  }) async {
    if (candidate.actionType != ServerMediaArchiveActionType.optimize ||
        !snapshot.candidates.any(
          (item) => item.candidateId == candidate.candidateId,
        )) {
      _invalid();
    }
    final requestId = _request();
    final map = _response(
      await api.request(
        'POST',
        '$root/preview',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'installationId': snapshot.authority.installationId,
          'expectedInstallationRevision':
              snapshot.authority.installationRevision,
          'expectedSnapshotRevision': snapshot.authority.snapshotRevision,
          'expectedPolicyRevision': snapshot.policy.revision,
          'candidateId': candidate.candidateId,
        },
      ),
      requestId,
      'preview',
    );
    final result = ServerMediaArchivePreview.fromJson(map['preview']);
    if (result.candidateId != candidate.candidateId ||
        result.operation != ServerMediaArchivePreviewOperation.stageTranscode ||
        result.reservedBytes > snapshot.policy.availableBytes) {
      _invalid();
    }
    return result;
  }

  Future<ServerMediaArchivePreview> previewCleanupCandidate({
    required ServerMediaArchiveSnapshot snapshot,
    required ServerMediaArchiveCandidate candidate,
  }) => _previewCleanup(
    snapshot: snapshot,
    candidateId: candidate.candidateId,
    sourceJob: null,
  );

  Future<ServerMediaArchivePreview> previewCleanupJob({
    required ServerMediaArchiveSnapshot snapshot,
    required ServerMediaArchiveJob sourceJob,
  }) => _previewCleanup(
    snapshot: snapshot,
    candidateId: null,
    sourceJob: sourceJob,
  );

  Future<ServerMediaArchivePreview> _previewCleanup({
    required ServerMediaArchiveSnapshot snapshot,
    required String? candidateId,
    required ServerMediaArchiveJob? sourceJob,
  }) async {
    if ((candidateId == null) == (sourceJob == null) ||
        candidateId != null &&
            !snapshot.candidates.any(
              (item) =>
                  item.candidateId == candidateId &&
                  item.actionType == ServerMediaArchiveActionType.cleanup,
            ) ||
        sourceJob != null &&
            (!sourceJob.cleanupAvailable ||
                !snapshot.jobs.any((item) => item.jobId == sourceJob.jobId))) {
      _invalid();
    }
    final requestId = _request();
    final body = <String, Object?>{
      'schemaVersion': 1,
      'requestId': requestId,
      'installationId': snapshot.authority.installationId,
      'expectedInstallationRevision': snapshot.authority.installationRevision,
      'expectedSnapshotRevision': snapshot.authority.snapshotRevision,
      'expectedPolicyRevision': snapshot.policy.revision,
    };
    if (candidateId != null) {
      body['candidateId'] = candidateId;
    } else {
      body['sourceJobId'] = sourceJob!.jobId;
      body['expectedSourceJobRevision'] = sourceJob.revision;
    }
    final map = _response(
      await api.request(
        'POST',
        '$root/cleanup/preview',
        token: token,
        body: body,
      ),
      requestId,
      'preview',
    );
    final result = ServerMediaArchivePreview.fromJson(map['preview']);
    if (result.operation == ServerMediaArchivePreviewOperation.stageTranscode ||
        candidateId != null && result.candidateId != candidateId) {
      _invalid();
    }
    return result;
  }

  Future<ServerMediaArchiveJob> confirm(
    ServerMediaArchivePreview preview,
  ) async {
    final cleanup =
        preview.operation != ServerMediaArchivePreviewOperation.stageTranscode;
    final requestId = _request();
    final map = _response(
      await api.request(
        'POST',
        cleanup ? '$root/cleanup/confirm' : '$root/confirm',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'previewId': preview.previewId,
          'expectedPreviewRevision': preview.revision,
        },
      ),
      requestId,
      'job',
    );
    final result = ServerMediaArchiveJob.fromJson(map['job']);
    if ((cleanup && result.kind != ServerMediaArchiveJobKind.cleanup) ||
        (!cleanup && result.kind != ServerMediaArchiveJobKind.optimize)) {
      _invalid();
    }
    return result;
  }

  Future<ServerMediaArchiveJob> readJob(ServerMediaArchiveJob previous) =>
      _jobAction('read', previous);

  Future<ServerMediaArchiveJob> cancelJob(ServerMediaArchiveJob previous) =>
      _jobAction('cancel', previous);

  Future<ServerMediaArchiveJob> reconcileJob(ServerMediaArchiveJob previous) =>
      _jobAction('reconcile', previous);

  Future<ServerMediaArchiveJob> _jobAction(
    String action,
    ServerMediaArchiveJob previous,
  ) async {
    if (action == 'cancel' && !previous.canCancel ||
        action == 'reconcile' && !previous.canReconcile) {
      _invalid();
    }
    final requestId = _request();
    final map = _response(
      await api.request(
        'POST',
        '$root/jobs/$action',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'jobId': previous.jobId,
          'expectedJobRevision': previous.revision,
        },
      ),
      requestId,
      'job',
    );
    final result = ServerMediaArchiveJob.fromJson(map['job']);
    if (!previous.sameIdentity(result) ||
        result.revision < previous.revision ||
        result.updatedAt.isBefore(previous.updatedAt) ||
        action != 'read' && result.revision <= previous.revision) {
      _invalid();
    }
    return result;
  }
}
