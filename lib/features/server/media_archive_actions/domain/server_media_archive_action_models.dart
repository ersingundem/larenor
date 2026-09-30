import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> archiveActionObject(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String archiveActionId(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String archiveActionDigest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int archiveActionInteger(
  Object? value, {
  int min = 0,
  int max = 0x7fffffffffffffff,
}) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

DateTime archiveActionTime(Object? value) {
  final seconds = archiveActionInteger(value, min: 1, max: 253402300799);
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

String _text(Object? value, {required int max}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value != value.trim() ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    _invalid();
  }
  return value;
}

enum ServerMediaArchiveCandidateKind { duplicate, transcode, retention }

enum ServerMediaArchiveActionType { optimize, cleanup }

enum ServerMediaArchiveConfidence { high, medium }

enum ServerMediaArchiveJobKind { optimize, cleanup }

enum ServerMediaArchiveJobState {
  queued,
  running,
  succeeded,
  failed,
  cancelled,
  needsAttention,
}

enum ServerMediaArchiveOriginalState {
  notApplicable,
  pending,
  retained,
  notRetained,
  removed,
  unknown,
}

enum ServerMediaArchivePreviewOperation {
  stageTranscode,
  cleanupDuplicate,
  cleanupRetention,
  cleanupRetainedOriginal,
}

final class ServerMediaArchivePolicy {
  const ServerMediaArchivePolicy._({
    required this.revision,
    required this.sharedQuotaBytes,
    required this.reservedBytes,
    required this.availableBytes,
  });

  factory ServerMediaArchivePolicy.fromJson(Object? value) {
    final map = archiveActionObject(value, {
      'schemaVersion',
      'revision',
      'sharedQuotaBytes',
      'reservedBytes',
      'availableBytes',
      'automaticCleanup',
    });
    if (map['schemaVersion'] != 1 || map['automaticCleanup'] != false) {
      _invalid();
    }
    final revision = archiveActionInteger(map['revision'], min: 1);
    final quota = archiveActionInteger(
      map['sharedQuotaBytes'],
      min: 256 * 1024 * 1024,
      max: 10 * 1024 * 1024 * 1024 * 1024,
    );
    final reserved = archiveActionInteger(
      map['reservedBytes'],
      max: 10 * 1024 * 1024 * 1024 * 1024,
    );
    final available = archiveActionInteger(
      map['availableBytes'],
      max: 10 * 1024 * 1024 * 1024 * 1024,
    );
    if (reserved > quota || available != quota - reserved) _invalid();
    return ServerMediaArchivePolicy._(
      revision: revision,
      sharedQuotaBytes: quota,
      reservedBytes: reserved,
      availableBytes: available,
    );
  }

  final int revision, sharedQuotaBytes, reservedBytes, availableBytes;
}

final class ServerMediaArchiveAuthority {
  const ServerMediaArchiveAuthority._({
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.sourceRevisions,
  });

  factory ServerMediaArchiveAuthority.fromJson(Object? value) {
    final map = archiveActionObject(value, {
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'sourceRevisions',
    });
    final raw = archiveActionObject(map['sourceRevisions'], {
      'jellyfin',
      'sonarr',
      'radarr',
      'qbittorrent',
    });
    return ServerMediaArchiveAuthority._(
      installationId: archiveActionId(map['installationId']),
      installationRevision: archiveActionInteger(
        map['installationRevision'],
        min: 1,
      ),
      snapshotRevision: archiveActionInteger(map['snapshotRevision'], min: 1),
      sourceRevisions: Map.unmodifiable({
        for (final entry in raw.entries)
          entry.key: archiveActionInteger(entry.value, min: 1),
      }),
    );
  }

  final String installationId;
  final int installationRevision, snapshotRevision;
  final Map<String, int> sourceRevisions;
}

final class ServerMediaArchiveComparison {
  const ServerMediaArchiveComparison._({
    required this.basis,
    required this.observedBytes,
    required this.estimatedRetainedBytes,
    required this.estimatedSavingBytes,
  });

  factory ServerMediaArchiveComparison.fromJson(Object? value) {
    final map = archiveActionObject(value, {
      'basis',
      'observedBytes',
      'estimatedRetainedBytes',
      'estimatedSavingBytes',
    });
    final basis = map['basis'];
    if (basis is! String ||
        !{
          'keep_largest_copy',
          'bounded_transcode_estimate',
          'review_retained_copy',
          'keep_best_quality_copy',
        }.contains(basis)) {
      _invalid();
    }
    final observed = archiveActionInteger(map['observedBytes'], min: 1);
    final retained = archiveActionInteger(map['estimatedRetainedBytes']);
    final saving = archiveActionInteger(map['estimatedSavingBytes'], min: 1);
    if (retained >= observed || observed - retained != saving) _invalid();
    return ServerMediaArchiveComparison._(
      basis: basis,
      observedBytes: observed,
      estimatedRetainedBytes: retained,
      estimatedSavingBytes: saving,
    );
  }

  final String basis;
  final int observedBytes, estimatedRetainedBytes, estimatedSavingBytes;
}

final class ServerMediaArchiveCandidate {
  const ServerMediaArchiveCandidate._({
    required this.candidateId,
    required this.kind,
    required this.title,
    required this.potentialBytes,
    required this.confidence,
    required this.comparison,
    required this.evidence,
    required this.actionType,
  });

  factory ServerMediaArchiveCandidate.fromJson(Object? value) {
    final map = archiveActionObject(value, {
      'candidateId',
      'kind',
      'title',
      'potentialBytes',
      'confidence',
      'comparison',
      'evidence',
      'actionType',
    });
    final kind = switch (map['kind']) {
      'duplicate' => ServerMediaArchiveCandidateKind.duplicate,
      'transcode' => ServerMediaArchiveCandidateKind.transcode,
      'retention' => ServerMediaArchiveCandidateKind.retention,
      _ => null,
    };
    final confidence = switch (map['confidence']) {
      'high' => ServerMediaArchiveConfidence.high,
      'medium' => ServerMediaArchiveConfidence.medium,
      _ => null,
    };
    final action = switch (map['actionType']) {
      'optimize' => ServerMediaArchiveActionType.optimize,
      'cleanup' => ServerMediaArchiveActionType.cleanup,
      _ => null,
    };
    final evidence = map['evidence'];
    const allowedEvidence = {
      'same_media_identity',
      'content_hash_match',
      'name_size_runtime_match',
      'quality_profile_comparison',
      'best_quality_excluded',
      'multiple_playable_files',
      'largest_copy_excluded',
      'source_profile_verified',
      'target_playback_verified',
      'bounded_size_estimate',
      'download_complete',
      'import_verified',
      'retention_policy_satisfied',
    };
    if (kind == null ||
        confidence == null ||
        action == null ||
        evidence is! List ||
        evidence.length != 3 ||
        evidence.any((item) => !allowedEvidence.contains(item)) ||
        (kind == ServerMediaArchiveCandidateKind.transcode) !=
            (action == ServerMediaArchiveActionType.optimize)) {
      _invalid();
    }
    final comparison = ServerMediaArchiveComparison.fromJson(map['comparison']);
    final potential = archiveActionInteger(map['potentialBytes'], min: 1);
    final expectedEvidence = switch (kind) {
      ServerMediaArchiveCandidateKind.duplicate => switch (comparison.basis) {
        'keep_largest_copy'
            when confidence == ServerMediaArchiveConfidence.high =>
          const [
            'content_hash_match',
            'multiple_playable_files',
            'largest_copy_excluded',
          ],
        'keep_largest_copy' => const [
          'name_size_runtime_match',
          'multiple_playable_files',
          'largest_copy_excluded',
        ],
        'keep_best_quality_copy' => const [
          'same_media_identity',
          'quality_profile_comparison',
          'best_quality_excluded',
        ],
        _ => null,
      },
      ServerMediaArchiveCandidateKind.transcode => const [
        'source_profile_verified',
        'target_playback_verified',
        'bounded_size_estimate',
      ],
      ServerMediaArchiveCandidateKind.retention => const [
        'download_complete',
        'import_verified',
        'retention_policy_satisfied',
      ],
    };
    final expectedBasis = switch (kind) {
      ServerMediaArchiveCandidateKind.transcode => 'bounded_transcode_estimate',
      ServerMediaArchiveCandidateKind.retention => 'review_retained_copy',
      ServerMediaArchiveCandidateKind.duplicate => comparison.basis,
    };
    if (comparison.estimatedSavingBytes != potential ||
        expectedEvidence == null ||
        !_sameStrings(evidence, expectedEvidence) ||
        comparison.basis != expectedBasis ||
        kind != ServerMediaArchiveCandidateKind.duplicate &&
            confidence != ServerMediaArchiveConfidence.medium ||
        kind == ServerMediaArchiveCandidateKind.duplicate &&
            comparison.basis == 'keep_best_quality_copy' &&
            confidence != ServerMediaArchiveConfidence.medium) {
      _invalid();
    }
    return ServerMediaArchiveCandidate._(
      candidateId: archiveActionDigest(map['candidateId']),
      kind: kind,
      title: _text(map['title'], max: 240),
      potentialBytes: potential,
      confidence: confidence,
      comparison: comparison,
      evidence: List.unmodifiable(evidence.cast<String>()),
      actionType: action,
    );
  }

  final String candidateId, title;
  final ServerMediaArchiveCandidateKind kind;
  final int potentialBytes;
  final ServerMediaArchiveConfidence confidence;
  final ServerMediaArchiveComparison comparison;
  final List<String> evidence;
  final ServerMediaArchiveActionType actionType;
}

bool _sameStrings(List<Object?> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class ServerMediaArchiveJob {
  const ServerMediaArchiveJob._({
    required this.jobId,
    required this.revision,
    required this.kind,
    required this.state,
    required this.phase,
    required this.cancelRequested,
    required this.reservedBytes,
    required this.originalState,
    required this.cleanupAvailable,
    required this.errorCode,
    required this.proofDigest,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ServerMediaArchiveJob.fromJson(Object? value) {
    final map = archiveActionObject(value, {
      'schemaVersion',
      'jobId',
      'revision',
      'kind',
      'state',
      'phase',
      'cancelRequested',
      'reservedBytes',
      'originalState',
      'cleanupAvailable',
      'errorCode',
      'proofDigest',
      'createdAt',
      'updatedAt',
    });
    if (map['schemaVersion'] != 2 ||
        map['cancelRequested'] is! bool ||
        map['cleanupAvailable'] is! bool) {
      _invalid();
    }
    final kind = switch (map['kind']) {
      'optimize' => ServerMediaArchiveJobKind.optimize,
      'cleanup' => ServerMediaArchiveJobKind.cleanup,
      _ => null,
    };
    final state = switch (map['state']) {
      'queued' => ServerMediaArchiveJobState.queued,
      'running' => ServerMediaArchiveJobState.running,
      'succeeded' => ServerMediaArchiveJobState.succeeded,
      'failed' => ServerMediaArchiveJobState.failed,
      'cancelled' => ServerMediaArchiveJobState.cancelled,
      'needs_attention' => ServerMediaArchiveJobState.needsAttention,
      _ => null,
    };
    final originalState = switch (map['originalState']) {
      'not_applicable' => ServerMediaArchiveOriginalState.notApplicable,
      'pending' => ServerMediaArchiveOriginalState.pending,
      'retained' => ServerMediaArchiveOriginalState.retained,
      'not_retained' => ServerMediaArchiveOriginalState.notRetained,
      'removed' => ServerMediaArchiveOriginalState.removed,
      'unknown' => ServerMediaArchiveOriginalState.unknown,
      _ => null,
    };
    final phase = map['phase'];
    final error = map['errorCode'];
    final proof = map['proofDigest'];
    const phases = {
      'queued',
      'preparing',
      'executing',
      'verifying',
      'complete',
      'failed',
      'cancelled',
      'needs_attention',
    };
    const errors = {
      'worker_unavailable',
      'authority_changed',
      'evidence_changed',
      'effect_unknown',
      'verification_failed',
      'cancel_unknown',
    };
    if (kind == null ||
        state == null ||
        originalState == null ||
        !phases.contains(phase) ||
        error != null && !errors.contains(error) ||
        proof != null &&
            (proof is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(proof))) {
      _invalid();
    }
    final created = archiveActionTime(map['createdAt']);
    final updated = archiveActionTime(map['updatedAt']);
    final expectedPhase = switch (state) {
      ServerMediaArchiveJobState.queued => 'queued',
      ServerMediaArchiveJobState.running => null,
      ServerMediaArchiveJobState.succeeded => 'complete',
      ServerMediaArchiveJobState.failed => 'failed',
      ServerMediaArchiveJobState.cancelled => 'cancelled',
      ServerMediaArchiveJobState.needsAttention => 'needs_attention',
    };
    if (updated.isBefore(created) ||
        (expectedPhase != null && phase != expectedPhase) ||
        state == ServerMediaArchiveJobState.running &&
            !{'preparing', 'executing', 'verifying'}.contains(phase) ||
        {
              ServerMediaArchiveJobState.failed,
              ServerMediaArchiveJobState.needsAttention,
            }.contains(state) !=
            (error != null) ||
        state == ServerMediaArchiveJobState.cancelled &&
            map['cancelRequested'] != true ||
        kind == ServerMediaArchiveJobKind.optimize &&
            (originalState == ServerMediaArchiveOriginalState.notApplicable ||
                archiveActionInteger(map['reservedBytes']) <= 0) ||
        kind == ServerMediaArchiveJobKind.cleanup &&
            (originalState != ServerMediaArchiveOriginalState.notApplicable ||
                archiveActionInteger(map['reservedBytes']) != 0) ||
        kind == ServerMediaArchiveJobKind.optimize &&
            {
              ServerMediaArchiveJobState.queued,
              ServerMediaArchiveJobState.running,
            }.contains(state) &&
            originalState != ServerMediaArchiveOriginalState.pending ||
        kind == ServerMediaArchiveJobKind.optimize &&
            state == ServerMediaArchiveJobState.succeeded &&
            !{
              ServerMediaArchiveOriginalState.retained,
              ServerMediaArchiveOriginalState.removed,
            }.contains(originalState) ||
        kind == ServerMediaArchiveJobKind.optimize &&
            {
              ServerMediaArchiveJobState.failed,
              ServerMediaArchiveJobState.cancelled,
            }.contains(state) &&
            !{
              ServerMediaArchiveOriginalState.notRetained,
              ServerMediaArchiveOriginalState.retained,
            }.contains(originalState) ||
        kind == ServerMediaArchiveJobKind.optimize &&
            state == ServerMediaArchiveJobState.needsAttention &&
            !{
              ServerMediaArchiveOriginalState.pending,
              ServerMediaArchiveOriginalState.retained,
              ServerMediaArchiveOriginalState.unknown,
            }.contains(originalState) ||
        map['cleanupAvailable'] == true &&
            (kind != ServerMediaArchiveJobKind.optimize ||
                state != ServerMediaArchiveJobState.succeeded ||
                originalState != ServerMediaArchiveOriginalState.retained) ||
        map['cancelRequested'] == true &&
            !{
              ServerMediaArchiveJobState.running,
              ServerMediaArchiveJobState.cancelled,
              ServerMediaArchiveJobState.needsAttention,
            }.contains(state) ||
        (proof != null) != (state == ServerMediaArchiveJobState.succeeded)) {
      _invalid();
    }
    return ServerMediaArchiveJob._(
      jobId: archiveActionId(map['jobId']),
      revision: archiveActionInteger(map['revision'], min: 1),
      kind: kind,
      state: state,
      phase: phase,
      cancelRequested: map['cancelRequested'] as bool,
      reservedBytes: archiveActionInteger(map['reservedBytes']),
      originalState: originalState,
      cleanupAvailable: map['cleanupAvailable'] as bool,
      errorCode: error as String?,
      proofDigest: proof as String?,
      createdAt: created,
      updatedAt: updated,
    );
  }

  final String jobId, phase;
  final int revision, reservedBytes;
  final ServerMediaArchiveJobKind kind;
  final ServerMediaArchiveJobState state;
  final bool cancelRequested, cleanupAvailable;
  final ServerMediaArchiveOriginalState originalState;
  final String? errorCode, proofDigest;
  final DateTime createdAt, updatedAt;

  bool get active =>
      state == ServerMediaArchiveJobState.queued ||
      state == ServerMediaArchiveJobState.running;
  bool get canCancel => active && !cancelRequested;
  bool get canReconcile => state == ServerMediaArchiveJobState.needsAttention;
  bool sameIdentity(ServerMediaArchiveJob other) =>
      jobId == other.jobId &&
      kind == other.kind &&
      createdAt == other.createdAt;
}

final class ServerMediaArchiveSnapshot {
  const ServerMediaArchiveSnapshot._({
    required this.revision,
    required this.policy,
    required this.authority,
    required this.candidates,
    required this.jobs,
    required this.generatedAt,
  });

  factory ServerMediaArchiveSnapshot.fromJson(Object? value) {
    final map = archiveActionObject(value, {
      'schemaVersion',
      'revision',
      'policy',
      'authority',
      'candidates',
      'jobs',
      'generatedAt',
    });
    if (map['schemaVersion'] != 1) _invalid();
    final rawCandidates = map['candidates'];
    final rawJobs = map['jobs'];
    if (rawCandidates is! List ||
        rawCandidates.length > 768 ||
        rawJobs is! List ||
        rawJobs.length > 64) {
      _invalid();
    }
    final candidates = rawCandidates
        .map(ServerMediaArchiveCandidate.fromJson)
        .toList();
    final jobs = rawJobs.map(ServerMediaArchiveJob.fromJson).toList();
    if (candidates.map((item) => item.candidateId).toSet().length !=
            candidates.length ||
        jobs.map((item) => item.jobId).toSet().length != jobs.length) {
      _invalid();
    }
    final revision = archiveActionInteger(map['revision'], min: 1);
    final policy = ServerMediaArchivePolicy.fromJson(map['policy']);
    if (revision != policy.revision) _invalid();
    return ServerMediaArchiveSnapshot._(
      revision: revision,
      policy: policy,
      authority: ServerMediaArchiveAuthority.fromJson(map['authority']),
      candidates: List.unmodifiable(candidates),
      jobs: List.unmodifiable(jobs),
      generatedAt: archiveActionTime(map['generatedAt']),
    );
  }

  final int revision;
  final ServerMediaArchivePolicy policy;
  final ServerMediaArchiveAuthority authority;
  final List<ServerMediaArchiveCandidate> candidates;
  final List<ServerMediaArchiveJob> jobs;
  final DateTime generatedAt;

  ServerMediaArchiveSnapshot withPolicy(ServerMediaArchivePolicy value) =>
      ServerMediaArchiveSnapshot._(
        revision: value.revision,
        policy: value,
        authority: authority,
        candidates: candidates,
        jobs: jobs,
        generatedAt: generatedAt,
      );

  ServerMediaArchiveSnapshot withJob(ServerMediaArchiveJob value) =>
      ServerMediaArchiveSnapshot._(
        revision: revision,
        policy: policy,
        authority: authority,
        candidates: candidates,
        jobs: List.unmodifiable(
          [value, ...jobs.where((item) => item.jobId != value.jobId)].take(64),
        ),
        generatedAt: generatedAt,
      );
}

final class ServerMediaArchivePreview {
  const ServerMediaArchivePreview._({
    required this.previewId,
    required this.revision,
    required this.candidateId,
    required this.operation,
    required this.reservedBytes,
    required this.originalWillBeRetained,
    required this.expiresAt,
  });

  factory ServerMediaArchivePreview.fromJson(Object? value) {
    final map = archiveActionObject(value, {
      'schemaVersion',
      'previewId',
      'revision',
      'candidateId',
      'operation',
      'reservedBytes',
      'originalWillBeRetained',
      'expiresAt',
      'confirmAvailable',
    });
    final operation = switch (map['operation']) {
      'stage_transcode' => ServerMediaArchivePreviewOperation.stageTranscode,
      'cleanup_duplicate' =>
        ServerMediaArchivePreviewOperation.cleanupDuplicate,
      'cleanup_retention' =>
        ServerMediaArchivePreviewOperation.cleanupRetention,
      'cleanup_retained_original' =>
        ServerMediaArchivePreviewOperation.cleanupRetainedOriginal,
      _ => null,
    };
    if (map['schemaVersion'] != 1 ||
        operation == null ||
        map['originalWillBeRetained'] is! bool ||
        map['confirmAvailable'] != true ||
        (operation == ServerMediaArchivePreviewOperation.stageTranscode) !=
            (map['originalWillBeRetained'] == true) ||
        (operation == ServerMediaArchivePreviewOperation.stageTranscode) !=
            (archiveActionInteger(map['reservedBytes']) > 0)) {
      _invalid();
    }
    return ServerMediaArchivePreview._(
      previewId: archiveActionId(map['previewId']),
      revision: archiveActionInteger(map['revision'], min: 1),
      candidateId: archiveActionDigest(map['candidateId']),
      operation: operation,
      reservedBytes: archiveActionInteger(map['reservedBytes']),
      originalWillBeRetained: map['originalWillBeRetained'] as bool,
      expiresAt: archiveActionTime(map['expiresAt']),
    );
  }

  final String previewId, candidateId;
  final int revision, reservedBytes;
  final ServerMediaArchivePreviewOperation operation;
  final bool originalWillBeRetained;
  final DateTime expiresAt;

  bool get expired => !expiresAt.isAfter(DateTime.now().toUtc());
}
