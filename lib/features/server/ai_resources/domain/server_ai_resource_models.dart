import '../../domain/server_models.dart';

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final json = serverObject(value);
  if (json.length != keys.length || !json.keys.every(keys.contains)) {
    throw const LarenorServerException('invalid_response');
  }
  return json;
}

int _integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

double _finite(Object? value) {
  if (value is! num || !value.isFinite || value < 0) {
    throw const LarenorServerException('invalid_response');
  }
  return value.toDouble();
}

final class AiResourcePolicy {
  const AiResourcePolicy._({
    required this.revision,
    required this.maxMemoryMb,
    required this.maxCpuPercent,
    required this.maxConcurrentJobs,
    required this.mediaCpuPercent,
    required this.updatedAt,
  });

  factory AiResourcePolicy.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'revision',
      'maxMemoryMb',
      'maxCpuPercent',
      'maxConcurrentJobs',
      'mediaCpuPercent',
      'updatedAt',
    });
    if (json['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final maxCpu = _integer(json['maxCpuPercent'], 1, 100);
    final mediaCpu = _integer(json['mediaCpuPercent'], 1, 100);
    if (mediaCpu > maxCpu) {
      throw const LarenorServerException('invalid_response');
    }
    return AiResourcePolicy._(
      revision: _integer(json['revision'], 1, 9223372036854775807),
      maxMemoryMb: _integer(json['maxMemoryMb'], 64, 1048576),
      maxCpuPercent: maxCpu,
      maxConcurrentJobs: _integer(json['maxConcurrentJobs'], 1, 16),
      mediaCpuPercent: mediaCpu,
      updatedAt: _finite(json['updatedAt']),
    );
  }

  final int revision,
      maxMemoryMb,
      maxCpuPercent,
      maxConcurrentJobs,
      mediaCpuPercent;
  final double updatedAt;
}

final class AiResourceCapacity {
  const AiResourceCapacity._({
    required this.memoryMb,
    required this.cpuCount,
    required this.effectiveCpuPercent,
    required this.allocatedMemoryMb,
    required this.allocatedCpuPercent,
    required this.processMemoryMb,
    required this.systemLoadPercent,
    required this.measuredAt,
    required this.mediaActive,
    required this.workerAvailable,
    required this.enforcement,
  });

  factory AiResourceCapacity.fromJson(Object? value) {
    final json = _closed(value, const {
      'memoryMb',
      'cpuCount',
      'effectiveCpuPercent',
      'allocatedMemoryMb',
      'allocatedCpuPercent',
      'processMemoryMb',
      'systemLoadPercent',
      'measuredAt',
      'mediaActive',
      'workerAvailable',
      'enforcement',
    });
    final enforcement = json['enforcement'];
    if (json['mediaActive'] is! bool ||
        json['workerAvailable'] is! bool ||
        !{'unavailable', 'systemdCgroupV2'}.contains(enforcement) ||
        (json['workerAvailable'] == true) !=
            (enforcement == 'systemdCgroupV2')) {
      throw const LarenorServerException('invalid_response');
    }
    return AiResourceCapacity._(
      memoryMb: _integer(json['memoryMb'], 64, 1048576),
      cpuCount: _integer(json['cpuCount'], 1, 4096),
      effectiveCpuPercent: _integer(json['effectiveCpuPercent'], 1, 100),
      allocatedMemoryMb: _integer(json['allocatedMemoryMb'], 0, 1048576),
      allocatedCpuPercent: _integer(json['allocatedCpuPercent'], 0, 100),
      processMemoryMb: _integer(json['processMemoryMb'], 0, 1048576),
      systemLoadPercent: _integer(json['systemLoadPercent'], 0, 100),
      measuredAt: _finite(json['measuredAt']),
      mediaActive: json['mediaActive'] as bool,
      workerAvailable: json['workerAvailable'] as bool,
      enforcement: enforcement as String,
    );
  }

  final int memoryMb,
      cpuCount,
      effectiveCpuPercent,
      allocatedMemoryMb,
      allocatedCpuPercent;
  final int processMemoryMb, systemLoadPercent;
  final double measuredAt;
  final bool mediaActive, workerAvailable;
  final String enforcement;
}

enum AiResourceJobState {
  queued,
  dispatching,
  running,
  blocked,
  cancelRequested,
  cancelled,
  completed,
  failed,
  uncertain;

  static AiResourceJobState parse(Object? value) => switch (value) {
    'queued' => queued,
    'dispatching' => dispatching,
    'running' => running,
    'blocked' => blocked,
    'cancel_requested' => cancelRequested,
    'cancelled' => cancelled,
    'completed' => completed,
    'failed' => failed,
    'uncertain' => uncertain,
    _ => throw const LarenorServerException('invalid_response'),
  };
}

final class AiResourceExecution {
  const AiResourceExecution._({
    required this.dispatchId,
    required this.provider,
    required this.phase,
    required this.startedAt,
    required this.finishedAt,
    required this.resultCode,
    required this.exitCode,
    required this.memoryPeakMb,
    required this.cpuMillis,
    required this.outputSha256,
    required this.outputBytes,
  });

  factory AiResourceExecution.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'dispatchId',
      'provider',
      'phase',
      'startedAt',
      'finishedAt',
      'resultCode',
      'exitCode',
      'memoryPeakMb',
      'cpuMillis',
      'outputSha256',
      'outputBytes',
    });
    final dispatchId = json['dispatchId'];
    final provider = json['provider'];
    final phase = json['phase'];
    final resultCode = json['resultCode'];
    final outputSha256 = json['outputSha256'];
    final outputBytes = json['outputBytes'];
    if (json['schemaVersion'] != 1 ||
        dispatchId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(dispatchId) ||
        provider is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(provider) ||
        !{
          'reserved',
          'starting',
          'running',
          'cancel_requested',
          'succeeded',
          'failed',
          'cancelled',
          'uncertain',
        }.contains(phase) ||
        (resultCode != null &&
            !{
              'succeeded',
              'provider_failed',
              'resource_limit',
              'cancelled',
              'runtime_lost',
            }.contains(resultCode)) ||
        (outputSha256 != null &&
            (outputSha256 is! String ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(outputSha256))) ||
        (outputSha256 == null) != (outputBytes == null)) {
      throw const LarenorServerException('invalid_response');
    }
    double? timestamp(Object? raw) => raw == null ? null : _finite(raw);
    int? integer(Object? raw, int max) =>
        raw == null ? null : _integer(raw, 0, max);
    return AiResourceExecution._(
      dispatchId: dispatchId,
      provider: provider,
      phase: phase as String,
      startedAt: timestamp(json['startedAt']),
      finishedAt: timestamp(json['finishedAt']),
      resultCode: resultCode as String?,
      exitCode: integer(json['exitCode'], 255),
      memoryPeakMb: integer(json['memoryPeakMb'], 1048576),
      cpuMillis: integer(json['cpuMillis'], 9007199254740991),
      outputSha256: outputSha256 as String?,
      outputBytes: integer(outputBytes, 1048576),
    );
  }

  final String dispatchId, provider, phase;
  final double? startedAt, finishedAt;
  final String? resultCode, outputSha256;
  final int? exitCode, memoryPeakMb, cpuMillis, outputBytes;
}

final class AiResourceJob {
  const AiResourceJob._({
    required this.id,
    required this.revision,
    required this.kind,
    required this.label,
    required this.priority,
    required this.memoryMb,
    required this.cpuPercent,
    required this.state,
    required this.reason,
    required this.execution,
    required this.ownedByCurrentSession,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AiResourceJob.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'id',
      'revision',
      'kind',
      'label',
      'priority',
      'memoryMb',
      'cpuPercent',
      'state',
      'reason',
      'execution',
      'ownedByCurrentSession',
      'createdAt',
      'updatedAt',
    });
    final id = json['id'];
    final kind = json['kind'];
    final reason = json['reason'];
    if (json['schemaVersion'] != 1 ||
        id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        !{'assistant', 'vision', 'embedding', 'automation'}.contains(kind) ||
        (reason != null &&
            !{
              'insufficientHardware',
              'mediaActive',
              'quotaExceeded',
              'higherPriorityWork',
              'workerUnavailable',
            }.contains(reason)) ||
        json['ownedByCurrentSession'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    final state = AiResourceJobState.parse(json['state']);
    final execution = json['execution'] == null
        ? null
        : AiResourceExecution.fromJson(json['execution']);
    final coherent = switch (state) {
      AiResourceJobState.queued ||
      AiResourceJobState.blocked => execution == null,
      AiResourceJobState.dispatching =>
        execution != null && {'reserved', 'starting'}.contains(execution.phase),
      AiResourceJobState.running => execution?.phase == 'running',
      AiResourceJobState.cancelRequested =>
        execution?.phase == 'cancel_requested',
      AiResourceJobState.cancelled =>
        execution == null || execution.phase == 'cancelled',
      AiResourceJobState.completed => execution?.phase == 'succeeded',
      AiResourceJobState.failed => execution?.phase == 'failed',
      AiResourceJobState.uncertain => execution?.phase == 'uncertain',
    };
    if (!coherent) {
      throw const LarenorServerException('invalid_response');
    }
    return AiResourceJob._(
      id: id,
      revision: _integer(json['revision'], 1, 9223372036854775807),
      kind: kind as String,
      label: serverText(json['label'], max: 80),
      priority: _integer(json['priority'], 0, 100),
      memoryMb: _integer(json['memoryMb'], 64, 1048576),
      cpuPercent: _integer(json['cpuPercent'], 1, 100),
      state: state,
      reason: reason as String?,
      execution: execution,
      ownedByCurrentSession: json['ownedByCurrentSession'] as bool,
      createdAt: _finite(json['createdAt']),
      updatedAt: _finite(json['updatedAt']),
    );
  }

  final String id, kind, label;
  final int revision, priority, memoryMb, cpuPercent;
  final AiResourceJobState state;
  final String? reason;
  final AiResourceExecution? execution;
  final bool ownedByCurrentSession;
  final double createdAt, updatedAt;
  bool get canCancel =>
      state == AiResourceJobState.running ||
      state == AiResourceJobState.dispatching ||
      state == AiResourceJobState.cancelRequested ||
      state == AiResourceJobState.uncertain ||
      state == AiResourceJobState.queued ||
      state == AiResourceJobState.blocked;
}

final class AiResourceSnapshot {
  const AiResourceSnapshot._(
    this.context,
    this.policy,
    this.capacity,
    this.jobs,
  );

  factory AiResourceSnapshot.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'scope',
      'policy',
      'capacity',
      'jobs',
    });
    final raw = json['jobs'];
    if (json['schemaVersion'] != 1 || raw is! List || raw.length > 512) {
      throw const LarenorServerException('invalid_response');
    }
    final jobs = raw.map(AiResourceJob.fromJson).toList();
    if (jobs.map((job) => job.id).toSet().length != jobs.length) {
      throw const LarenorServerException('invalid_response');
    }
    return AiResourceSnapshot._(
      ServerContext.fromJson(json['scope']),
      AiResourcePolicy.fromJson(json['policy']),
      AiResourceCapacity.fromJson(json['capacity']),
      List.unmodifiable(jobs),
    );
  }

  final ServerContext context;
  final AiResourcePolicy policy;
  final AiResourceCapacity capacity;
  final List<AiResourceJob> jobs;
}

enum AiResourcePreset {
  conservative(memoryMb: 1024, cpuPercent: 40, jobs: 1, mediaCpuPercent: 15),
  balanced(memoryMb: 2048, cpuPercent: 70, jobs: 2, mediaCpuPercent: 25),
  performance(memoryMb: 4096, cpuPercent: 90, jobs: 4, mediaCpuPercent: 35);

  const AiResourcePreset({
    required this.memoryMb,
    required this.cpuPercent,
    required this.jobs,
    required this.mediaCpuPercent,
  });
  final int memoryMb, cpuPercent, jobs, mediaCpuPercent;
}
