import '../../domain/server_models.dart';
import '../../plugins/domain/server_plugin_job_models.dart';
import '../domain/server_media_preparation_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');
String _choice(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) _invalid();
  return value;
}

String _digest(Object? value) {
  if (value is! String ||
      value.length != 64 ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

bool _bool(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

DateTime _time(Object? value) {
  if (value is! String ||
      value.length != 24 ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
          .hasMatch(value)) {
    _invalid();
  }
  final time = DateTime.tryParse(value);
  if (time == null || time.toIso8601String() != value) _invalid();
  return time;
}

class ServerMediaInspectionCapabilities {
  const ServerMediaInspectionCapabilities._(this.inspectionConfigured);
  final bool inspectionConfigured;
  factory ServerMediaInspectionCapabilities.fromJson(Object? value) {
    final json = mediaObject(value, {
      'inspectionConfigured',
      'installAvailable',
    });
    if (json['installAvailable'] != false) _invalid();
    return ServerMediaInspectionCapabilities._(
      _bool(json['inspectionConfigured']),
    );
  }
}

/// Durable observations only; completion does not authorize installation.
class ServerMediaInspection {
  ServerMediaInspection._(Map<String, dynamic> json)
    : id = mediaId(json['id']),
      requestId = mediaId(json['requestId']),
      preparationId = mediaId(json['preparationId']),
      preparationRevision = mediaInteger(json['preparationRevision'], max: 1),
      coreId = mediaId(json['coreId']),
      homeId = mediaId(json['homeId']),
      catalogDigest = _digest(json['catalogDigest']),
      planHash = _digest(json['planHash']),
      platform = _choice(json['platform'], {'linux/amd64', 'linux/arm64'}),
      revision = mediaInteger(json['revision'], max: 0x7ffffffffffffffe),
      state = _choice(json['state'], pluginJobStates),
      phase = _choice(json['phase'], {
        'queued',
        'checking_requirements',
        'complete',
      }),
      cancelRequested = _bool(json['cancelRequested']),
      createdAt = _time(json['createdAt']),
      updatedAt = _time(json['updatedAt']),
      result = json['result'] == null
          ? null
          : ServerPluginJobResult.fromJson(json['result']),
      errorCode = json['errorCode'] == null
          ? null
          : _choice(json['errorCode'], {
              'worker_unavailable',
              'invalid_worker_result',
              'authority_changed',
              'catalog_changed',
              'preparation_changed',
              'context_changed',
            }) {
    if (updatedAt.isBefore(createdAt)) _invalid();
    if (active) {
      if (phase != (state == 'queued' ? 'queued' : 'checking_requirements') ||
          result != null ||
          errorCode != null ||
          (state == 'queued' && (cancelRequested || revision != 1)) ||
          (state == 'running' && revision < 2)) {
        _invalid();
      }
    } else if (phase != 'complete' || revision < 2) {
      _invalid();
    }
    if (state == 'succeeded') {
      if (result == null ||
          errorCode != null ||
          cancelRequested ||
          result!.planHash != planHash ||
          result!.catalogDigest != catalogDigest ||
          result!.platform != platform) {
        _invalid();
      }
    } else if (result != null) {
      _invalid();
    }
    if (state == 'failed' &&
        (!{'worker_unavailable', 'invalid_worker_result'}.contains(errorCode) ||
            cancelRequested)) {
      _invalid();
    }
    if (state == 'needs_attention' &&
        (!{
              'authority_changed',
              'catalog_changed',
              'preparation_changed',
              'context_changed',
            }.contains(errorCode) ||
            cancelRequested)) {
      _invalid();
    }
    if (state == 'cancelled' && (!cancelRequested || errorCode != null)) {
      _invalid();
    }
  }
  factory ServerMediaInspection.fromJson(Object? value) =>
      ServerMediaInspection._(
        mediaObject(value, {
          'id',
          'requestId',
          'preparationId',
          'preparationRevision',
          'coreId',
          'homeId',
          'catalogDigest',
          'planHash',
          'platform',
          'revision',
          'state',
          'phase',
          'cancelRequested',
          'createdAt',
          'updatedAt',
          'result',
          'errorCode',
        }),
      );
  final String id,
      requestId,
      preparationId,
      coreId,
      homeId,
      catalogDigest,
      planHash,
      platform,
      state,
      phase;
  final int preparationRevision, revision;
  final bool cancelRequested;
  final DateTime createdAt, updatedAt;
  final ServerPluginJobResult? result;
  final String? errorCode;
  bool get active => state == 'queued' || state == 'running';
  ServerContext get context => ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
  });
  bool sameIdentity(ServerMediaInspection other) =>
      id == other.id &&
      requestId == other.requestId &&
      preparationId == other.preparationId &&
      preparationRevision == other.preparationRevision &&
      context == other.context &&
      catalogDigest == other.catalogDigest &&
      planHash == other.planHash &&
      platform == other.platform &&
      createdAt == other.createdAt;
  bool matchesPreparation(ServerMediaPreparation preparation) =>
      preparation.id == preparationId &&
      preparation.plan.coreId == coreId &&
      preparation.plan.homeId == homeId &&
      preparation.plan.catalogDigest == catalogDigest &&
      preparation.plan.planHash == planHash &&
      preparation.plan.platform == platform;
}

class ServerMediaInspectionRequest {
  ServerMediaInspectionRequest(this.preparation, String requestId)
    : requestId = mediaId(requestId) {
    if (!preparation.prepared || !preparation.catalogCurrent) _invalid();
  }
  final ServerMediaPreparation preparation;
  final String requestId;
  Map<String, Object> toJson() => {
    'requestId': requestId,
    'preparationId': preparation.id,
    'expectedRevision': preparation.revision,
    'planHash': preparation.plan.planHash,
  };
  bool accepts(ServerMediaInspection inspection) =>
      inspection.requestId == requestId &&
      inspection.preparationRevision == preparation.revision &&
      inspection.matchesPreparation(preparation);
  @override
  String toString() => 'ServerMediaInspectionRequest';
}
