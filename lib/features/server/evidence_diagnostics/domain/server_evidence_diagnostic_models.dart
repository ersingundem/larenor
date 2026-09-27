import '../../domain/server_models.dart';

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final json = serverObject(value);
  if (json.length != keys.length || !json.keys.every(keys.contains)) {
    throw const LarenorServerException('invalid_response');
  }
  return json;
}

List<Map<String, dynamic>> _objects(Object? value, {int max = 128}) {
  if (value is! List || value.length > max) {
    throw const LarenorServerException('invalid_response');
  }
  return value.map(serverObject).toList();
}

final class DiagnosticEvidenceSource {
  const DiagnosticEvidenceSource({
    required this.id,
    required this.type,
    required this.revision,
    required this.state,
    required this.detailRedacted,
    required this.measurementCount,
    required this.eventCount,
  });

  factory DiagnosticEvidenceSource.fromJson(Object? value) {
    final json = _closed(value, const {
      'sourceId',
      'sourceType',
      'revision',
      'capturedAtMs',
      'state',
      'detailRedacted',
      'measurements',
      'events',
    });
    final revision = json['revision'];
    final capturedAt = json['capturedAtMs'];
    final type = json['sourceType'];
    final state = json['state'];
    if (revision is! int ||
        revision < 1 ||
        capturedAt is! int ||
        capturedAt < 0 ||
        !{'health', 'event', 'measurement'}.contains(type) ||
        !{
          'healthy',
          'attention',
          'degraded',
          'critical',
          'unavailable',
          'unknown',
        }.contains(state) ||
        json['detailRedacted'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    return DiagnosticEvidenceSource(
      id: serverText(json['sourceId'], max: 96),
      type: type as String,
      revision: revision,
      state: state as String,
      detailRedacted: json['detailRedacted'] as bool,
      measurementCount: _objects(json['measurements'], max: 32).length,
      eventCount: _objects(json['events'], max: 32).length,
    );
  }

  final String id, type, state;
  final int revision, measurementCount, eventCount;
  final bool detailRedacted;
}

final class EvidenceDiagnosis {
  const EvidenceDiagnosis._({
    required this.id,
    required this.revision,
    required this.createdAtMs,
    required this.status,
    required this.certainty,
    required this.sources,
    required this.findingCodes,
    required this.unknownCodes,
    required this.recommendationCodes,
    required this.redactionCount,
  });

  factory EvidenceDiagnosis.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'id',
      'revision',
      'createdAtMs',
      'status',
      'certainty',
      'readOnly',
      'applied',
      'sources',
      'findings',
      'unknowns',
      'recommendations',
      'redactions',
    });
    final id = json['id'];
    final revision = json['revision'];
    final createdAtMs = json['createdAtMs'];
    final status = json['status'];
    final certainty = json['certainty'];
    if (json['schemaVersion'] != 1 ||
        id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        revision is! int ||
        revision < 1 ||
        createdAtMs is! int ||
        createdAtMs < 0 ||
        !{'fault', 'unknown', 'no_issue'}.contains(status) ||
        !{'limited', 'supported'}.contains(certainty) ||
        json['readOnly'] != true ||
        json['applied'] != false) {
      throw const LarenorServerException('invalid_response');
    }
    final sources = _objects(
      json['sources'],
      max: 32,
    ).map(DiagnosticEvidenceSource.fromJson).toList();
    final findings = _objects(json['findings']);
    final unknowns = _objects(json['unknowns']);
    final recommendations = _objects(json['recommendations']);
    final redactions = _objects(json['redactions']);
    String code(Map<String, dynamic> item) => serverText(item['code'], max: 96);
    return EvidenceDiagnosis._(
      id: id,
      revision: revision,
      createdAtMs: createdAtMs,
      status: status as String,
      certainty: certainty as String,
      sources: List.unmodifiable(sources),
      findingCodes: List.unmodifiable(findings.map(code)),
      unknownCodes: List.unmodifiable(unknowns.map(code)),
      recommendationCodes: List.unmodifiable(recommendations.map(code)),
      redactionCount: redactions.length,
    );
  }

  final String id, status, certainty;
  final int revision, createdAtMs, redactionCount;
  final List<DiagnosticEvidenceSource> sources;
  final List<String> findingCodes, unknownCodes, recommendationCodes;
}

final class DiagnosticRepairPreview {
  const DiagnosticRepairPreview._({
    required this.id,
    required this.diagnosisId,
    required this.expiresAtMs,
    required this.stepCodes,
  });

  factory DiagnosticRepairPreview.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'id',
      'diagnosisId',
      'diagnosisRevision',
      'createdAtMs',
      'expiresAtMs',
      'authorizedRole',
      'authorizedSessionFamilyId',
      'previewOnly',
      'applied',
      'executionAvailable',
      'steps',
    });
    final id = json['id'];
    final diagnosisId = json['diagnosisId'];
    final expiresAtMs = json['expiresAtMs'];
    if (json['schemaVersion'] != 1 ||
        id is! String ||
        diagnosisId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(diagnosisId) ||
        expiresAtMs is! int ||
        expiresAtMs < 0 ||
        json['authorizedRole'] != 'admin' ||
        json['previewOnly'] != true ||
        json['applied'] != false ||
        json['executionAvailable'] != false) {
      throw const LarenorServerException('invalid_response');
    }
    final steps = _objects(json['steps'], max: 128);
    return DiagnosticRepairPreview._(
      id: id,
      diagnosisId: diagnosisId,
      expiresAtMs: expiresAtMs,
      stepCodes: List.unmodifiable(
        steps.map((item) => serverText(item['code'], max: 96)),
      ),
    );
  }

  final String id, diagnosisId;
  final int expiresAtMs;
  final List<String> stepCodes;
}
