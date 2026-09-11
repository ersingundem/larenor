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
  downloadComplete,
  importVerified,
  retentionPolicySatisfied,
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
  static bool _boundedText(Object? value, int max) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= max &&
      value == value.trim() &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

  final String installationId;
  final int installationRevision, snapshotRevision;
  final MediaArchiveSnapshotState state;
  final Map<String, MediaArchiveSourceState> sourceStates;
  final Map<String, int> sourceRevisions;
  final MediaArchiveCounts counts;
  final List<MediaArchiveIssue> issues;
  final List<MediaArchiveSavingSuggestion> suggestions;
  bool get cleanupAvailable => false;
  final DateTime generatedAt;
}

final class MediaArchiveReadException implements Exception {
  const MediaArchiveReadException(this.kind);
  final String kind;
  @override
  String toString() => 'MediaArchiveReadException($kind)';
}
