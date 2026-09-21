import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _closed(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.length != keys.length ||
      value.keys.any((key) => !keys.contains(key))) {
    _invalid();
  }
  return value;
}

String _identity(Object? raw) {
  if (raw is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(raw)) _invalid();
  return raw;
}

int _revision(Object? raw) {
  if (raw is! int || raw < 1 || raw > 0x7fffffffffffffff) _invalid();
  return raw;
}

String _safeText(Object? raw, {int maximum = 240}) {
  if (raw is! String ||
      raw.trim().isEmpty ||
      raw.length > maximum ||
      raw.codeUnits.any(
        (unit) => unit < 0x20 || (unit >= 0x7f && unit <= 0x9f),
      )) {
    _invalid();
  }
  return raw.trim();
}

DateTime _time(Object? raw) {
  if (raw is! int || raw < 0 || raw > 0x7fffffffffffffff) _invalid();
  return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
}

enum CameraSearchMode { localMetadata, semanticAssisted }

enum CameraSearchStatus { ready, degraded }

enum CameraSearchDegradedReason { semanticProviderUnavailable }

@immutable
final class CameraSearchContext {
  CameraSearchContext({
    required this.coreId,
    required this.homeId,
    required this.indexRevision,
    required List<String> cameraIds,
  }) : cameraIds = List.unmodifiable(cameraIds);

  factory CameraSearchContext.fromJson(Object? raw, ServerContext context) {
    final value = _closed(raw, {
      'schemaVersion',
      'coreId',
      'homeId',
      'indexRevision',
      'cameraIds',
      'maxWindowDays',
    });
    final cameras = value['cameraIds'];
    if (value['schemaVersion'] != 1 ||
        value['coreId'] != context.coreId ||
        value['homeId'] != context.homeId ||
        value['maxWindowDays'] != 31 ||
        cameras is! List ||
        cameras.isEmpty ||
        cameras.length > 64) {
      _invalid();
    }
    final ids = cameras.map(_identity).toList(growable: false);
    if (ids.toSet().length != ids.length) _invalid();
    return CameraSearchContext(
      coreId: context.coreId,
      homeId: context.homeId,
      indexRevision: _revision(value['indexRevision']),
      cameraIds: ids,
    );
  }

  final String coreId, homeId;
  final int indexRevision;
  final List<String> cameraIds;
}

@immutable
final class CameraSearchFilter {
  CameraSearchFilter({
    required this.expectedIndexRevision,
    required this.start,
    required this.end,
    required List<String> cameraIds,
  }) : cameraIds = List.unmodifiable(cameraIds) {
    if (expectedIndexRevision < 1 ||
        !end.isAfter(start) ||
        end.difference(start) > const Duration(days: 31) ||
        cameraIds.isEmpty ||
        cameraIds.length > 16 ||
        cameraIds.toSet().length != cameraIds.length ||
        cameraIds.any((id) => !RegExp(r'^[0-9a-f]{32}$').hasMatch(id))) {
      throw ArgumentError('invalid camera search filter');
    }
  }

  final int expectedIndexRevision;
  final DateTime start, end;
  final List<String> cameraIds;
}

@immutable
final class CameraSearchEvidence {
  const CameraSearchEvidence({
    required this.coreId,
    required this.homeId,
    required this.cameraId,
    required this.clipId,
    required this.eventId,
    required this.captureRevision,
    required this.indexRevision,
    required this.capturedAt,
  });

  final String coreId, homeId, cameraId, clipId, eventId;
  final int captureRevision, indexRevision;
  final DateTime capturedAt;
}

@immutable
final class CameraSearchMatch {
  const CameraSearchMatch({
    required this.start,
    required this.end,
    required this.summary,
    required this.matchedTerms,
    required this.evidence,
  });

  final DateTime start, end;
  final String summary;
  final List<String> matchedTerms;
  final CameraSearchEvidence evidence;
}

@immutable
final class CameraSearchPage {
  const CameraSearchPage({
    required this.indexRevision,
    required this.mode,
    required this.status,
    required this.degradedReason,
    required this.results,
    this.nextCursor,
  });

  factory CameraSearchPage.fromJson(Object? raw, ServerContext context) {
    final value = _closed(raw, {
      'schemaVersion',
      'indexRevision',
      'mode',
      'status',
      'degradedReason',
      'results',
      'nextCursor',
    });
    if (value['schemaVersion'] != 1) _invalid();
    final indexRevision = _revision(value['indexRevision']);
    final mode = switch (value['mode']) {
      'local_metadata' => CameraSearchMode.localMetadata,
      'semantic_assisted' => CameraSearchMode.semanticAssisted,
      _ => _invalid(),
    };
    final status = switch (value['status']) {
      'ready' => CameraSearchStatus.ready,
      'degraded' => CameraSearchStatus.degraded,
      _ => _invalid(),
    };
    final degraded = switch (value['degradedReason']) {
      null => null,
      'semantic_provider_unavailable' =>
        CameraSearchDegradedReason.semanticProviderUnavailable,
      _ => _invalid(),
    };
    if ((status == CameraSearchStatus.degraded) != (degraded != null) ||
        (status == CameraSearchStatus.ready &&
            mode != CameraSearchMode.semanticAssisted)) {
      _invalid();
    }
    final rawResults = value['results'];
    if (rawResults is! List || rawResults.length > 50) _invalid();
    final results = rawResults
        .map((rawMatch) {
          final match = _closed(rawMatch, {
            'schemaVersion',
            'startMs',
            'endMs',
            'summary',
            'matchedTerms',
            'evidence',
          });
          final evidence = _closed(match['evidence'], {
            'schemaVersion',
            'kind',
            'coreId',
            'homeId',
            'cameraId',
            'clipId',
            'eventId',
            'captureRevision',
            'indexRevision',
            'capturedAtMs',
          });
          if (match['schemaVersion'] != 1 ||
              evidence['schemaVersion'] != 1 ||
              evidence['kind'] != 'camera_evidence' ||
              evidence['coreId'] != context.coreId ||
              evidence['homeId'] != context.homeId ||
              evidence['indexRevision'] != indexRevision) {
            _invalid();
          }
          final start = _time(match['startMs']);
          final end = _time(match['endMs']);
          final captured = _time(evidence['capturedAtMs']);
          if (!end.isAfter(start) ||
              captured.isBefore(start) ||
              captured.isAfter(end)) {
            _invalid();
          }
          final rawTerms = match['matchedTerms'];
          if (rawTerms is! List || rawTerms.isEmpty || rawTerms.length > 16) {
            _invalid();
          }
          final terms = rawTerms.map(_safeText).toList(growable: false);
          if (terms.toSet().length != terms.length) _invalid();
          return CameraSearchMatch(
            start: start,
            end: end,
            summary: _safeText(match['summary']),
            matchedTerms: List.unmodifiable(terms),
            evidence: CameraSearchEvidence(
              coreId: context.coreId,
              homeId: context.homeId,
              cameraId: _identity(evidence['cameraId']),
              clipId: _identity(evidence['clipId']),
              eventId: _identity(evidence['eventId']),
              captureRevision: _revision(evidence['captureRevision']),
              indexRevision: indexRevision,
              capturedAt: captured,
            ),
          );
        })
        .toList(growable: false);
    final cursor = value['nextCursor'];
    if (cursor != null &&
        (cursor is! String ||
            cursor.length < 40 ||
            cursor.length > 512 ||
            !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(cursor))) {
      _invalid();
    }
    return CameraSearchPage(
      indexRevision: indexRevision,
      mode: mode,
      status: status,
      degradedReason: degraded,
      results: List.unmodifiable(results),
      nextCursor: cursor as String?,
    );
  }

  final int indexRevision;
  final CameraSearchMode mode;
  final CameraSearchStatus status;
  final CameraSearchDegradedReason? degradedReason;
  final List<CameraSearchMatch> results;
  final String? nextCursor;
}

abstract interface class CameraSearchGateway {
  Future<CameraSearchPage> search({
    required String query,
    required CameraSearchFilter filter,
    String? cursor,
  });

  void retire();
}
