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
    required this.mediaActive,
  });

  factory AiResourceCapacity.fromJson(Object? value) {
    final json = _closed(value, const {
      'memoryMb',
      'cpuCount',
      'effectiveCpuPercent',
      'allocatedMemoryMb',
      'allocatedCpuPercent',
      'mediaActive',
    });
    if (json['mediaActive'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    return AiResourceCapacity._(
      memoryMb: _integer(json['memoryMb'], 64, 1048576),
      cpuCount: _integer(json['cpuCount'], 1, 4096),
      effectiveCpuPercent: _integer(json['effectiveCpuPercent'], 1, 100),
      allocatedMemoryMb: _integer(json['allocatedMemoryMb'], 0, 1048576),
      allocatedCpuPercent: _integer(json['allocatedCpuPercent'], 0, 100),
      mediaActive: json['mediaActive'] as bool,
    );
  }

  final int memoryMb,
      cpuCount,
      effectiveCpuPercent,
      allocatedMemoryMb,
      allocatedCpuPercent;
  final bool mediaActive;
}

enum AiResourceJobState {
  queued,
  running,
  blocked,
  cancelled,
  completed;

  static AiResourceJobState parse(Object? value) => switch (value) {
    'queued' => queued,
    'running' => running,
    'blocked' => blocked,
    'cancelled' => cancelled,
    'completed' => completed,
    _ => throw const LarenorServerException('invalid_response'),
  };
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
            }.contains(reason)) ||
        json['ownedByCurrentSession'] is! bool) {
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
      state: AiResourceJobState.parse(json['state']),
      reason: reason as String?,
      ownedByCurrentSession: json['ownedByCurrentSession'] as bool,
      createdAt: _finite(json['createdAt']),
      updatedAt: _finite(json['updatedAt']),
    );
  }

  final String id, kind, label;
  final int revision, priority, memoryMb, cpuPercent;
  final AiResourceJobState state;
  final String? reason;
  final bool ownedByCurrentSession;
  final double createdAt, updatedAt;
  bool get canCancel =>
      state == AiResourceJobState.running ||
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
