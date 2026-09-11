import '../../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _id(Object? value, {int length = 32}) {
  if (value is! String ||
      value.length != length ||
      !RegExp(
        '^[0-9a-f]{$length}'
        r'$',
      ).hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _integer(Object? value, {int min = 0, int max = 0x7fffffffffffffff}) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

bool _boundedText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    value == value.trim() &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

enum MediaArchiveSnapshotState { healthy, attention, incomplete }

enum MediaArchiveSourceState { verified, unavailable, unsupported, stale }

enum MediaArchiveIssueCode {
  missingMedia,
  missingFile,
  corruptMedia,
  unplayableMedia,
  downloadError,
}

enum MediaArchiveIssueSeverity { warning, critical }

enum MediaArchiveSavingEvidence {
  sameMediaIdentity,
  contentHashMatch,
  nameSizeRuntimeMatch,
  qualityProfileComparison,
  bestQualityExcluded,
  multiplePlayableFiles,
  largestCopyExcluded,
  sourceProfileVerified,
  targetPlaybackVerified,
  boundedSizeEstimate,
  downloadComplete,
  importVerified,
  retentionPolicySatisfied,
}

enum MediaArchiveSavingKind { duplicate, transcode, retention }

enum MediaArchiveSavingConfidence { high, medium }

enum MediaArchiveSavingGroupReason {
  exactContentHash,
  probableNameSizeRuntime,
  lowerQualityVariant,
  notApplicable,
}

enum MediaArchiveSavingComparisonBasis {
  keepLargestCopy,
  boundedTranscodeEstimate,
  reviewRetainedCopy,
  keepBestQualityCopy,
}

enum MediaArchiveSavingGapReason {
  partial,
  unsupported,
  unavailable,
  stale,
  truncated,
}

enum MediaArchiveSavingLaneState {
  verified,
  partial,
  unsupported,
  unavailable,
  stale,
}

final class MediaArchiveSavingsComparison {
  const MediaArchiveSavingsComparison._({
    required this.basis,
    required this.observedBytes,
    required this.estimatedRetainedBytes,
    required this.estimatedSavingBytes,
  });

  factory MediaArchiveSavingsComparison.fromJson(Object? value) {
    final map = _object(value, {
      'basis',
      'observedBytes',
      'estimatedRetainedBytes',
      'estimatedSavingBytes',
    });
    final basis = switch (map['basis']) {
      'keep_largest_copy' => MediaArchiveSavingComparisonBasis.keepLargestCopy,
      'bounded_transcode_estimate' =>
        MediaArchiveSavingComparisonBasis.boundedTranscodeEstimate,
      'review_retained_copy' =>
        MediaArchiveSavingComparisonBasis.reviewRetainedCopy,
      'keep_best_quality_copy' =>
        MediaArchiveSavingComparisonBasis.keepBestQualityCopy,
      _ => null,
    };
    final observed = _integer(map['observedBytes'], min: 1);
    final retained = _integer(map['estimatedRetainedBytes']);
    final saving = _integer(map['estimatedSavingBytes'], min: 1);
    if (basis == null ||
        retained >= observed ||
        observed - retained != saving) {
      _invalid();
    }
    return MediaArchiveSavingsComparison._(
      basis: basis,
      observedBytes: observed,
      estimatedRetainedBytes: retained,
      estimatedSavingBytes: saving,
    );
  }

  final MediaArchiveSavingComparisonBasis basis;
  final int observedBytes, estimatedRetainedBytes, estimatedSavingBytes;
}

final class MediaArchiveSavingsDataGap {
  const MediaArchiveSavingsDataGap._({
    required this.lane,
    required this.reason,
  });
  final MediaArchiveSavingKind lane;
  final MediaArchiveSavingGapReason reason;
}

final class MediaArchiveSavingsCandidate {
  const MediaArchiveSavingsCandidate._({
    required this.kind,
    required this.source,
    required this.title,
    required this.potentialBytes,
    required this.groupReason,
    required this.confidence,
    required this.comparison,
    required this.evidence,
  });
  final MediaArchiveSavingKind kind;
  final String source, title;
  final int potentialBytes;
  final MediaArchiveSavingGroupReason groupReason;
  final MediaArchiveSavingConfidence confidence;
  final MediaArchiveSavingsComparison comparison;
  final List<MediaArchiveSavingEvidence> evidence;
  bool get actionAvailable => false;
}

final class MediaArchiveSavingsPlan {
  const MediaArchiveSavingsPlan._({
    required this.ready,
    required this.laneStates,
    required this.candidates,
    required this.candidateCounts,
    required this.totalPotentialBytes,
    required this.dataGaps,
    required this.truncated,
  });

  factory MediaArchiveSavingsPlan.fromJson(Object? value) {
    final map = _object(value, {
      'state',
      'laneStates',
      'candidates',
      'candidateCounts',
      'totalPotentialBytes',
      'dataGaps',
      'truncated',
      'actionAvailable',
    });
    final state = map['state'];
    final lanes = _object(map['laneStates'], _savingKinds);
    final counts = _object(map['candidateCounts'], _savingKinds);
    final raw = map['candidates'];
    final rawGaps = map['dataGaps'];
    if (!{'ready', 'partial'}.contains(state) ||
        raw is! List ||
        raw.length > 768 ||
        rawGaps is! List ||
        rawGaps.length > 3 ||
        map['truncated'] is! bool ||
        map['actionAvailable'] != false) {
      _invalid();
    }
    final parsedLanes = <MediaArchiveSavingKind, MediaArchiveSavingLaneState>{};
    final parsedCounts = <MediaArchiveSavingKind, int>{};
    for (final kind in MediaArchiveSavingKind.values) {
      final lane = MediaArchiveSavingLaneState.values
          .where((candidate) => candidate.name == lanes[kind.name])
          .firstOrNull;
      if (lane == null) _invalid();
      parsedLanes[kind] = lane;
      parsedCounts[kind] = _integer(counts[kind.name], max: 256);
    }
    final candidates = raw.map(_candidate).toList();
    final dataGaps = rawGaps.map(_dataGap).toList();
    for (final kind in MediaArchiveSavingKind.values) {
      if (candidates.where((value) => value.kind == kind).length !=
          parsedCounts[kind]) {
        _invalid();
      }
    }
    final total = _integer(map['totalPotentialBytes']);
    final truncated = map['truncated'] as bool;
    final gapKeys = dataGaps
        .map((gap) => '${gap.lane.name}:${gap.reason.name}')
        .toList();
    final expectedGapKeys = <String>[];
    for (final kind in MediaArchiveSavingKind.values) {
      final lane = parsedLanes[kind]!;
      if (lane != MediaArchiveSavingLaneState.verified) {
        expectedGapKeys.add('${kind.name}:${lane.name}');
      } else if (dataGaps.any(
        (gap) =>
            gap.lane == kind &&
            gap.reason == MediaArchiveSavingGapReason.truncated,
      )) {
        expectedGapKeys.add('${kind.name}:truncated');
      }
    }
    if (total !=
            candidates.fold<int>(0, (sum, item) => sum + item.potentialBytes) ||
        candidates.any(
          (item) =>
              parsedLanes[item.kind] != MediaArchiveSavingLaneState.verified,
        ) ||
        gapKeys.toSet().length != gapKeys.length ||
        !_sameList(gapKeys, expectedGapKeys) ||
        truncated !=
            dataGaps.any(
              (gap) => gap.reason == MediaArchiveSavingGapReason.truncated,
            ) ||
        (state == 'ready') != dataGaps.isEmpty) {
      _invalid();
    }
    return MediaArchiveSavingsPlan._(
      ready: state == 'ready',
      laneStates: Map.unmodifiable(parsedLanes),
      candidates: List.unmodifiable(candidates),
      candidateCounts: Map.unmodifiable(parsedCounts),
      totalPotentialBytes: total,
      dataGaps: List.unmodifiable(dataGaps),
      truncated: truncated,
    );
  }

  static MediaArchiveSavingsCandidate _candidate(Object? value) {
    final map = _object(value, {
      'kind',
      'source',
      'title',
      'potentialBytes',
      'groupReason',
      'confidence',
      'comparison',
      'evidence',
      'actionAvailable',
    });
    final kind = MediaArchiveSavingKind.values
        .where((candidate) => candidate.name == map['kind'])
        .firstOrNull;
    final evidence = map['evidence'];
    if (kind == null ||
        evidence is! List ||
        evidence.length != 3 ||
        !_boundedText(map['title'], 240) ||
        map['actionAvailable'] != false) {
      _invalid();
    }
    final groupReason = switch (map['groupReason']) {
      'exact_content_hash' => MediaArchiveSavingGroupReason.exactContentHash,
      'probable_name_size_runtime' =>
        MediaArchiveSavingGroupReason.probableNameSizeRuntime,
      'lower_quality_variant' =>
        MediaArchiveSavingGroupReason.lowerQualityVariant,
      'not_applicable' => MediaArchiveSavingGroupReason.notApplicable,
      _ => null,
    };
    final expected = switch (kind) {
      MediaArchiveSavingKind.duplicate => switch (groupReason) {
        MediaArchiveSavingGroupReason.exactContentHash => (
          'jellyfin',
          MediaArchiveSavingConfidence.high,
          MediaArchiveSavingComparisonBasis.keepLargestCopy,
          const [
            'content_hash_match',
            'multiple_playable_files',
            'largest_copy_excluded',
          ],
        ),
        MediaArchiveSavingGroupReason.probableNameSizeRuntime => (
          'jellyfin',
          MediaArchiveSavingConfidence.medium,
          MediaArchiveSavingComparisonBasis.keepLargestCopy,
          const [
            'name_size_runtime_match',
            'multiple_playable_files',
            'largest_copy_excluded',
          ],
        ),
        MediaArchiveSavingGroupReason.lowerQualityVariant => (
          'jellyfin',
          MediaArchiveSavingConfidence.medium,
          MediaArchiveSavingComparisonBasis.keepBestQualityCopy,
          const [
            'same_media_identity',
            'quality_profile_comparison',
            'best_quality_excluded',
          ],
        ),
        _ => null,
      },
      MediaArchiveSavingKind.transcode => (
        'jellyfin',
        MediaArchiveSavingConfidence.medium,
        MediaArchiveSavingComparisonBasis.boundedTranscodeEstimate,
        const [
          'source_profile_verified',
          'target_playback_verified',
          'bounded_size_estimate',
        ],
      ),
      MediaArchiveSavingKind.retention => (
        'qbittorrent',
        MediaArchiveSavingConfidence.medium,
        MediaArchiveSavingComparisonBasis.reviewRetainedCopy,
        const [
          'download_complete',
          'import_verified',
          'retention_policy_satisfied',
        ],
      ),
    };
    final confidence = MediaArchiveSavingConfidence.values
        .where((value) => value.name == map['confidence'])
        .firstOrNull;
    final comparison = MediaArchiveSavingsComparison.fromJson(
      map['comparison'],
    );
    final potential = _integer(map['potentialBytes'], min: 1);
    if (expected == null ||
        groupReason == null ||
        map['source'] != expected.$1 ||
        confidence != expected.$2 ||
        (kind != MediaArchiveSavingKind.duplicate &&
            groupReason != MediaArchiveSavingGroupReason.notApplicable) ||
        comparison.basis != expected.$3 ||
        comparison.estimatedSavingBytes != potential ||
        !_sameList(evidence, expected.$4)) {
      _invalid();
    }
    return MediaArchiveSavingsCandidate._(
      kind: kind,
      source: expected.$1,
      title: map['title'] as String,
      potentialBytes: potential,
      groupReason: groupReason,
      confidence: confidence!,
      comparison: comparison,
      evidence: List.unmodifiable(
        evidence.map(
          (value) => switch (value) {
            'same_media_identity' =>
              MediaArchiveSavingEvidence.sameMediaIdentity,
            'content_hash_match' => MediaArchiveSavingEvidence.contentHashMatch,
            'name_size_runtime_match' =>
              MediaArchiveSavingEvidence.nameSizeRuntimeMatch,
            'quality_profile_comparison' =>
              MediaArchiveSavingEvidence.qualityProfileComparison,
            'best_quality_excluded' =>
              MediaArchiveSavingEvidence.bestQualityExcluded,
            'multiple_playable_files' =>
              MediaArchiveSavingEvidence.multiplePlayableFiles,
            'largest_copy_excluded' =>
              MediaArchiveSavingEvidence.largestCopyExcluded,
            'source_profile_verified' =>
              MediaArchiveSavingEvidence.sourceProfileVerified,
            'target_playback_verified' =>
              MediaArchiveSavingEvidence.targetPlaybackVerified,
            'bounded_size_estimate' =>
              MediaArchiveSavingEvidence.boundedSizeEstimate,
            'download_complete' => MediaArchiveSavingEvidence.downloadComplete,
            'import_verified' => MediaArchiveSavingEvidence.importVerified,
            'retention_policy_satisfied' =>
              MediaArchiveSavingEvidence.retentionPolicySatisfied,
            _ => throw const LarenorServerException('invalid_response'),
          },
        ),
      ),
    );
  }

  static MediaArchiveSavingsDataGap _dataGap(Object? value) {
    final map = _object(value, {'lane', 'reason'});
    final lane = MediaArchiveSavingKind.values
        .where((value) => value.name == map['lane'])
        .firstOrNull;
    final reason = MediaArchiveSavingGapReason.values
        .where((value) => value.name == map['reason'])
        .firstOrNull;
    if (lane == null || reason == null) _invalid();
    return MediaArchiveSavingsDataGap._(lane: lane, reason: reason);
  }

  static bool _sameList(List<dynamic> actual, List<String> expected) {
    if (actual.length != expected.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (actual[index] != expected[index]) return false;
    }
    return true;
  }

  static const _savingKinds = {'duplicate', 'transcode', 'retention'};
  final bool ready, truncated;
  final Map<MediaArchiveSavingKind, MediaArchiveSavingLaneState> laneStates;
  final List<MediaArchiveSavingsCandidate> candidates;
  final Map<MediaArchiveSavingKind, int> candidateCounts;
  final int totalPotentialBytes;
  final List<MediaArchiveSavingsDataGap> dataGaps;
  bool get actionAvailable => false;
}

final class MediaArchiveIssue {
  const MediaArchiveIssue._({
    required this.code,
    required this.severity,
    required this.source,
    required this.title,
    required this.observedBytes,
  });
  final MediaArchiveIssueCode code;
  final MediaArchiveIssueSeverity severity;
  final String source, title;
  final int observedBytes;
}

final class MediaArchiveSavingSuggestion {
  const MediaArchiveSavingSuggestion._({
    required this.title,
    required this.potentialBytes,
    required this.evidence,
  });
  final String title;
  final int potentialBytes;
  final List<MediaArchiveSavingEvidence> evidence;
  bool get cleanupAvailable => false;
}

final class MediaArchiveCounts {
  const MediaArchiveCounts({
    required this.missing,
    required this.broken,
    required this.failedDownloads,
    required this.savingCandidates,
    required this.potentialSavingBytes,
  });

  factory MediaArchiveCounts.fromJson(Object? value) {
    final map = _object(value, {
      'missing',
      'broken',
      'failedDownloads',
      'savingCandidates',
      'potentialSavingBytes',
    });
    return MediaArchiveCounts(
      missing: _integer(map['missing'], max: 8192),
      broken: _integer(map['broken'], max: 8192),
      failedDownloads: _integer(map['failedDownloads'], max: 4096),
      savingCandidates: _integer(map['savingCandidates'], max: 4096),
      potentialSavingBytes: _integer(map['potentialSavingBytes']),
    );
  }

  final int missing;
  final int broken;
  final int failedDownloads;
  final int savingCandidates;
  final int potentialSavingBytes;
}

enum MediaArchiveWeeklyTrendState { ready, stale, unavailable }

final class MediaArchiveWeeklyTrendPoint {
  const MediaArchiveWeeklyTrendPoint._({
    required this.weekStart,
    required this.capturedAt,
    required this.snapshotRevision,
    required this.totalBytes,
    required this.freeBytes,
    required this.reclaimableBytes,
    required this.duplicateCandidates,
    required this.lowQualityCandidates,
  });

  factory MediaArchiveWeeklyTrendPoint.fromJson(Object? value) {
    final map = _object(value, {
      'weekStart',
      'capturedAt',
      'snapshotRevision',
      'totalBytes',
      'freeBytes',
      'reclaimableBytes',
      'duplicateCandidates',
      'lowQualityCandidates',
    });
    final week = _integer(map['weekStart'], min: 1);
    final captured = _integer(map['capturedAt'], min: 1);
    final total = _integer(map['totalBytes'], min: 1);
    final free = _integer(map['freeBytes']);
    if (free > total ||
        week % 86400 != 0 ||
        ((week ~/ 86400) + 3) % 7 != 0 ||
        captured < week ||
        captured >= week + 604800) {
      _invalid();
    }
    return MediaArchiveWeeklyTrendPoint._(
      weekStart: DateTime.fromMillisecondsSinceEpoch(week * 1000, isUtc: true),
      capturedAt: DateTime.fromMillisecondsSinceEpoch(
        captured * 1000,
        isUtc: true,
      ),
      snapshotRevision: _integer(map['snapshotRevision'], min: 1),
      totalBytes: total,
      freeBytes: free,
      reclaimableBytes: _integer(map['reclaimableBytes']),
      duplicateCandidates: _integer(map['duplicateCandidates'], max: 256),
      lowQualityCandidates: _integer(map['lowQualityCandidates'], max: 256),
    );
  }

  final DateTime weekStart, capturedAt;
  final int snapshotRevision, totalBytes, freeBytes, reclaimableBytes;
  final int duplicateCandidates, lowQualityCandidates;
}

final class MediaArchiveWeeklyTrend {
  const MediaArchiveWeeklyTrend._({required this.state, required this.points});

  factory MediaArchiveWeeklyTrend.fromJson(Object? value) {
    final map = _object(value, {'state', 'points', 'actionAvailable'});
    final state = MediaArchiveWeeklyTrendState.values
        .where((candidate) => candidate.name == map['state'])
        .firstOrNull;
    final values = map['points'];
    if (state == null ||
        values is! List ||
        values.length > 12 ||
        map['actionAvailable'] != false) {
      _invalid();
    }
    final points = values
        .map(MediaArchiveWeeklyTrendPoint.fromJson)
        .toList(growable: false);
    if ((state == MediaArchiveWeeklyTrendState.unavailable) != points.isEmpty) {
      _invalid();
    }
    for (var index = 1; index < points.length; index++) {
      final left = points[index - 1], right = points[index];
      if (!left.weekStart.isBefore(right.weekStart) ||
          !left.capturedAt.isBefore(right.capturedAt) ||
          left.snapshotRevision >= right.snapshotRevision) {
        _invalid();
      }
    }
    return MediaArchiveWeeklyTrend._(
      state: state,
      points: List.unmodifiable(points),
    );
  }

  final MediaArchiveWeeklyTrendState state;
  final List<MediaArchiveWeeklyTrendPoint> points;
  bool get actionAvailable => false;
}

final class MediaArchiveHealthSnapshot {
  const MediaArchiveHealthSnapshot._({
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.state,
    required this.sourceStates,
    required this.sourceRevisions,
    required this.counts,
    required this.issues,
    required this.suggestions,
    required this.savingsPlan,
    required this.weeklyTrend,
    required this.generatedAt,
  });

  factory MediaArchiveHealthSnapshot.fromJson(Object? value) {
    final map = _object(value, {
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'state',
      'sourceStates',
      'sourceRevisions',
      'counts',
      'issues',
      'suggestions',
      'savingsPlan',
      'weeklyTrend',
      'cleanupAvailable',
      'generatedAt',
    });
    final state = MediaArchiveSnapshotState.values
        .where((candidate) => candidate.name == map['state'])
        .firstOrNull;
    final sourceStates = _object(map['sourceStates'], _services);
    final sourceRevisions = _object(map['sourceRevisions'], _services);
    final issues = map['issues'], suggestions = map['suggestions'];
    if (state == null ||
        issues is! List ||
        issues.length > 12288 ||
        suggestions is! List ||
        suggestions.length > 4096 ||
        map['cleanupAvailable'] != false) {
      _invalid();
    }
    // Public detail rows remain bounded and secret-free even though this card
    // only renders aggregate counts.
    final parsedIssues = <MediaArchiveIssue>[];
    for (final issue in issues) {
      final item = _object(issue, {
        'code',
        'severity',
        'source',
        'sourceItemId',
        'mediaKey',
        'title',
        'observedBytes',
      });
      if (!_issueCodes.contains(item['code']) ||
          !{'warning', 'critical'}.contains(item['severity']) ||
          !_services.contains(item['source']) ||
          !_boundedText(item['sourceItemId'], 96) ||
          !(item['mediaKey'] == null || _boundedText(item['mediaKey'], 192)) ||
          !_boundedText(item['title'], 256) ||
          _integer(item['observedBytes']) < 0) {
        _invalid();
      }
      parsedIssues.add(
        MediaArchiveIssue._(
          code: switch (item['code']) {
            'missing_media' => MediaArchiveIssueCode.missingMedia,
            'missing_file' => MediaArchiveIssueCode.missingFile,
            'corrupt_media' => MediaArchiveIssueCode.corruptMedia,
            'unplayable_media' => MediaArchiveIssueCode.unplayableMedia,
            'download_error' => MediaArchiveIssueCode.downloadError,
            _ => throw const LarenorServerException('invalid_response'),
          },
          severity: item['severity'] == 'critical'
              ? MediaArchiveIssueSeverity.critical
              : MediaArchiveIssueSeverity.warning,
          source: item['source'] as String,
          title: item['title'] as String,
          observedBytes: item['observedBytes'] as int,
        ),
      );
    }
    final parsedSuggestions = <MediaArchiveSavingSuggestion>[];
    for (final suggestion in suggestions) {
      final item = _object(suggestion, {
        'code',
        'torrentId',
        'mediaKey',
        'title',
        'potentialBytes',
        'evidence',
        'cleanupAvailable',
      });
      final evidence = item['evidence'];
      final torrentId = item['torrentId'];
      if (item['code'] != 'review_retained_download' ||
          torrentId is! String ||
          !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(torrentId) ||
          !_boundedText(item['mediaKey'], 192) ||
          !_boundedText(item['title'], 256) ||
          _integer(item['potentialBytes'], min: 1) < 1 ||
          evidence is! List ||
          evidence.length != 3 ||
          evidence.join('|') !=
              'download_complete|import_verified|retention_policy_satisfied' ||
          item['cleanupAvailable'] != false) {
        _invalid();
      }
      parsedSuggestions.add(
        MediaArchiveSavingSuggestion._(
          title: item['title'] as String,
          potentialBytes: item['potentialBytes'] as int,
          evidence: List.unmodifiable(
            evidence.map(
              (value) => switch (value) {
                'download_complete' =>
                  MediaArchiveSavingEvidence.downloadComplete,
                'import_verified' => MediaArchiveSavingEvidence.importVerified,
                'retention_policy_satisfied' =>
                  MediaArchiveSavingEvidence.retentionPolicySatisfied,
                _ => throw const LarenorServerException('invalid_response'),
              },
            ),
          ),
        ),
      );
    }
    final parsedStates = <String, MediaArchiveSourceState>{};
    final parsedRevisions = <String, int>{};
    for (final service in _services) {
      final source = MediaArchiveSourceState.values
          .where((candidate) => candidate.name == sourceStates[service])
          .firstOrNull;
      if (source == null) _invalid();
      parsedStates[service] = source;
      parsedRevisions[service] = _integer(sourceRevisions[service], min: 1);
    }
    return MediaArchiveHealthSnapshot._(
      installationId: _id(map['installationId']),
      installationRevision: _integer(map['installationRevision'], min: 1),
      snapshotRevision: _integer(map['snapshotRevision'], min: 1),
      state: state,
      sourceStates: Map.unmodifiable(parsedStates),
      sourceRevisions: Map.unmodifiable(parsedRevisions),
      counts: MediaArchiveCounts.fromJson(map['counts']),
      issues: List.unmodifiable(parsedIssues),
      suggestions: List.unmodifiable(parsedSuggestions),
      savingsPlan: MediaArchiveSavingsPlan.fromJson(map['savingsPlan']),
      weeklyTrend: MediaArchiveWeeklyTrend.fromJson(map['weeklyTrend']),
      generatedAt: DateTime.fromMillisecondsSinceEpoch(
        _integer(map['generatedAt'], min: 1) * 1000,
        isUtc: true,
      ),
    );
  }

  static const _services = {'jellyfin', 'sonarr', 'radarr', 'qbittorrent'};
  static const _issueCodes = {
    'missing_media',
    'missing_file',
    'corrupt_media',
    'unplayable_media',
    'download_error',
  };
  final String installationId;
  final int installationRevision, snapshotRevision;
  final MediaArchiveSnapshotState state;
  final Map<String, MediaArchiveSourceState> sourceStates;
  final Map<String, int> sourceRevisions;
  final MediaArchiveCounts counts;
  final List<MediaArchiveIssue> issues;
  final List<MediaArchiveSavingSuggestion> suggestions;
  final MediaArchiveSavingsPlan savingsPlan;
  final MediaArchiveWeeklyTrend weeklyTrend;
  bool get cleanupAvailable => false;
  final DateTime generatedAt;
}

final class MediaArchiveReadException implements Exception {
  const MediaArchiveReadException(this.kind);
  final String kind;
  @override
  String toString() => 'MediaArchiveReadException($kind)';
}
