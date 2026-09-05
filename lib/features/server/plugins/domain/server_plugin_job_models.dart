import '../../domain/server_models.dart';
import 'server_plugin_models.dart';

const pluginJobStates = {
  'queued',
  'running',
  'succeeded',
  'failed',
  'cancelled',
  'needs_attention',
};
const pluginJobEventCodes = {
  'job_queued',
  'job_started',
  'job_resumed',
  'job_completed',
  'job_failed',
  'job_cancel_requested',
  'job_cancelled',
  'job_needs_attention',
};
const pluginJobErrors = {
  'worker_unavailable',
  'invalid_worker_result',
  'authority_changed',
  'catalog_changed',
  'storage_unavailable',
};

Never _invalid() => throw const LarenorServerException('invalid_response');
Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _choice(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) _invalid();
  return value;
}

String _pattern(Object? value, String pattern) {
  if (value is! String || !RegExp(pattern).hasMatch(value)) _invalid();
  return value;
}

int pluginJobInteger(Object? value, {int minimum = 1}) {
  if (value is! int || value < minimum || value > 0x7fffffffffffffff) {
    _invalid();
  }
  return value;
}

String pluginJobId(Object? value) => _pattern(value, r'^[a-f0-9]{32}$');
String _digest(Object? value) => _pattern(value, r'^[a-f0-9]{64}$');
bool _boolean(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

DateTime _time(Object? value) {
  final text = _pattern(
    value,
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
  );
  final parsed = DateTime.tryParse(text);
  if (parsed == null || parsed.toIso8601String() != text) _invalid();
  return parsed;
}

class ServerPluginJobCapabilities {
  const ServerPluginJobCapabilities._(this.preflightConfigured);
  final bool preflightConfigured;
  factory ServerPluginJobCapabilities.fromJson(Object? value) {
    final json = _object(value, {'preflightConfigured', 'installAvailable'});
    if (json['installAvailable'] != false) _invalid();
    return ServerPluginJobCapabilities._(_boolean(json['preflightConfigured']));
  }
}

class ServerPluginJobCheck {
  const ServerPluginJobCheck._(
    this.code,
    this.status,
    this.rootId,
    this.availableMiB,
    this.requiredMiB,
  );
  final String code, status;
  final String? rootId;
  final int? availableMiB, requiredMiB;
  factory ServerPluginJobCheck.fromJson(Object? value) {
    final json = _object(value, {
      'code',
      'status',
      'rootId',
      'availableMiB',
      'requiredMiB',
    });
    if (json['code'] is String &&
        (json['code'] as String).startsWith('daemon_') &&
        (json['rootId'] != null ||
            json['availableMiB'] != null ||
            json['requiredMiB'] != null)) {
      _invalid();
    }
    return ServerPluginJobCheck._(
      _choice(json['code'], {
        'platform',
        'storage_root',
        'storage_capacity',
        'docker_engine',
        'daemon_mount_context',
        'daemon_network_context',
        'daemon_root_context',
        'port_availability',
        'receiver_network',
      }),
      _choice(json['status'], {'passed', 'failed', 'unknown'}),
      json['rootId'] == null
          ? null
          : _pattern(json['rootId'], r'^[a-z][a-z0-9_-]{0,39}$'),
      json['availableMiB'] == null
          ? null
          : pluginJobInteger(json['availableMiB'], minimum: 0),
      json['requiredMiB'] == null
          ? null
          : pluginJobInteger(json['requiredMiB'], minimum: 0),
    );
  }
}

class ServerPluginJobResult {
  const ServerPluginJobResult._(
    this.catalogDigest,
    this.planHash,
    this.platform,
    this.checkedAt,
    this.checks,
  );
  final String catalogDigest, planHash, platform;
  final DateTime checkedAt;
  final List<ServerPluginJobCheck> checks;
  factory ServerPluginJobResult.fromJson(Object? value) {
    final json = _object(value, {
      'catalogDigest',
      'planHash',
      'platform',
      'checkedAt',
      'checks',
    });
    final checks = json['checks'];
    if (checks is! List || checks.isEmpty || checks.length > 32) _invalid();
    return ServerPluginJobResult._(
      _digest(json['catalogDigest']),
      _digest(json['planHash']),
      _choice(json['platform'], pluginPlatforms),
      _time(json['checkedAt']),
      List.unmodifiable(checks.map(ServerPluginJobCheck.fromJson)),
    );
  }
}

class ServerPluginJob {
  const ServerPluginJob._({
    required this.id,
    required this.revision,
    required this.previewId,
    required this.requestId,
    required this.serviceId,
    required this.distributionId,
    required this.planHash,
    required this.platform,
    required this.state,
    required this.phase,
    required this.cancelRequested,
    required this.createdAt,
    required this.updatedAt,
    required this.result,
    required this.errorCode,
  });
  final String id,
      previewId,
      requestId,
      serviceId,
      distributionId,
      planHash,
      platform,
      state,
      phase;
  final int revision;
  final bool cancelRequested;
  final DateTime createdAt, updatedAt;
  final ServerPluginJobResult? result;
  final String? errorCode;
  bool get active => state == 'queued' || state == 'running';
  bool sameIdentity(ServerPluginJob other) =>
      id == other.id &&
      previewId == other.previewId &&
      requestId == other.requestId &&
      serviceId == other.serviceId &&
      distributionId == other.distributionId &&
      planHash == other.planHash &&
      platform == other.platform &&
      createdAt == other.createdAt;
  factory ServerPluginJob.fromJson(Object? value) {
    final json = _object(value, {
      'id',
      'revision',
      'operation',
      'previewId',
      'requestId',
      'serviceId',
      'distributionId',
      'planHash',
      'platform',
      'state',
      'phase',
      'cancelRequested',
      'createdAt',
      'updatedAt',
      'result',
      'errorCode',
    });
    _choice(json['operation'], {'preflight'});
    final job = ServerPluginJob._(
      id: pluginJobId(json['id']),
      revision: pluginJobInteger(json['revision']),
      previewId: pluginJobId(json['previewId']),
      requestId: pluginJobId(json['requestId']),
      serviceId: _choice(json['serviceId'], pluginServiceIds),
      distributionId: _choice(json['distributionId'], {
        'upstream',
        'linuxserver',
      }),
      planHash: _digest(json['planHash']),
      platform: _choice(json['platform'], pluginPlatforms),
      state: _choice(json['state'], pluginJobStates),
      phase: _choice(json['phase'], {
        'queued',
        'checking_requirements',
        'complete',
      }),
      cancelRequested: _boolean(json['cancelRequested']),
      createdAt: _time(json['createdAt']),
      updatedAt: _time(json['updatedAt']),
      result: json['result'] == null
          ? null
          : ServerPluginJobResult.fromJson(json['result']),
      errorCode: json['errorCode'] == null
          ? null
          : _choice(json['errorCode'], pluginJobErrors),
    );
    if (job.updatedAt.isBefore(job.createdAt)) _invalid();
    if (job.active) {
      if (job.phase !=
              (job.state == 'queued' ? 'queued' : 'checking_requirements') ||
          job.result != null ||
          job.errorCode != null ||
          (job.state == 'queued' && job.cancelRequested)) {
        _invalid();
      }
    } else if (job.phase != 'complete') {
      _invalid();
    }
    if (job.state == 'succeeded') {
      if (job.result == null ||
          job.errorCode != null ||
          job.cancelRequested ||
          job.result!.planHash != job.planHash ||
          job.result!.platform != job.platform) {
        _invalid();
      }
    } else if (job.result != null) {
      _invalid();
    }
    if (job.state == 'failed' &&
        (!{
              'worker_unavailable',
              'invalid_worker_result',
            }.contains(job.errorCode) ||
            job.cancelRequested)) {
      _invalid();
    }
    if (job.state == 'needs_attention' &&
        (!{
              'authority_changed',
              'catalog_changed',
              'storage_unavailable',
            }.contains(job.errorCode) ||
            job.cancelRequested)) {
      _invalid();
    }
    if (job.state == 'cancelled' &&
        (!job.cancelRequested || job.errorCode != null)) {
      _invalid();
    }
    return job;
  }
}

class ServerPluginJobEvent {
  const ServerPluginJobEvent._(
    this.sequence,
    this.code,
    this.createdAt,
    this.jobRevision,
  );
  final int sequence, jobRevision;
  final String code;
  final DateTime createdAt;
  factory ServerPluginJobEvent.fromJson(Object? value) {
    final json = _object(value, {
      'sequence',
      'code',
      'createdAt',
      'jobRevision',
    });
    return ServerPluginJobEvent._(
      pluginJobInteger(json['sequence']),
      _choice(json['code'], pluginJobEventCodes),
      _time(json['createdAt']),
      pluginJobInteger(json['jobRevision']),
    );
  }
}

class ServerPluginJobRequest {
  ServerPluginJobRequest(this.preview, String requestId)
    : requestId = pluginJobId(requestId);
  final ServerPluginPreview preview;
  final String requestId;
  Map<String, Object> toJson() => {
    'operation': 'preflight',
    'previewId': preview.id,
    'expectedRevision': preview.revision,
    'planHash': preview.plan.planHash,
    'requestId': requestId,
  };
  bool accepts(ServerPluginJob job) =>
      job.previewId == preview.id &&
      job.requestId == requestId &&
      job.serviceId == preview.plan.serviceId &&
      job.distributionId == preview.plan.distributionId &&
      job.planHash == preview.plan.planHash &&
      job.platform == preview.plan.image.platform &&
      (job.result == null ||
          job.result!.catalogDigest == preview.plan.catalogDigest);
  @override
  String toString() => 'ServerPluginJobRequest';
}
