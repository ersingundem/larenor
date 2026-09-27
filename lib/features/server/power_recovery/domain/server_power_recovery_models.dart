import '../../domain/server_models.dart';

DateTime _time(Object? value) {
  if (value is! int || value < 0 || value > 253402300799) {
    throw const LarenorServerException('invalid_response');
  }
  return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
}

String _identity(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

int _revision(Object? value, {bool allowZero = false}) {
  if (value is! int || value < (allowZero ? 0 : 1)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

void _keys(Map<String, dynamic> json, Set<String> expected) {
  if (json.length != expected.length || !json.keys.every(expected.contains)) {
    throw const LarenorServerException('invalid_response');
  }
}

enum PowerTargetKind { service, proxmoxGuest, networkDevice, coreHost }

final class PowerRecoveryTarget {
  const PowerRecoveryTarget({
    required this.targetId,
    required this.label,
    required this.kind,
    required this.shutdownOrder,
    required this.startOnRestore,
    required this.timeoutSeconds,
  });

  factory PowerRecoveryTarget.fromJson(Object? raw) {
    final json = serverObject(raw);
    _keys(json, const {
      'targetId',
      'label',
      'kind',
      'shutdownOrder',
      'startOnRestore',
      'timeoutSeconds',
    });
    final label = json['label'];
    final order = json['shutdownOrder'];
    final start = json['startOnRestore'];
    final timeout = json['timeoutSeconds'];
    final kind = switch (json['kind']) {
      'service' => PowerTargetKind.service,
      'proxmoxGuest' => PowerTargetKind.proxmoxGuest,
      'networkDevice' => PowerTargetKind.networkDevice,
      'coreHost' => PowerTargetKind.coreHost,
      _ => throw const LarenorServerException('invalid_response'),
    };
    if (label is! String ||
        label.isEmpty ||
        label.length > 80 ||
        order is! int ||
        order < 1 ||
        order > 1000 ||
        start is! bool ||
        timeout is! int ||
        timeout < 5 ||
        timeout > 300) {
      throw const LarenorServerException('invalid_response');
    }
    return PowerRecoveryTarget(
      targetId: _identity(json['targetId']),
      label: label,
      kind: kind,
      shutdownOrder: order,
      startOnRestore: start,
      timeoutSeconds: timeout,
    );
  }

  final String targetId;
  final String label;
  final PowerTargetKind kind;
  final int shutdownOrder;
  final bool startOnRestore;
  final int timeoutSeconds;

  Map<String, Object> toJson() => {
    'targetId': targetId,
    'label': label,
    'kind': switch (kind) {
      PowerTargetKind.service => 'service',
      PowerTargetKind.proxmoxGuest => 'proxmoxGuest',
      PowerTargetKind.networkDevice => 'networkDevice',
      PowerTargetKind.coreHost => 'coreHost',
    },
    'shutdownOrder': shutdownOrder,
    'startOnRestore': startOnRestore,
    'timeoutSeconds': timeoutSeconds,
  };
}

final class PowerRecoveryPolicy {
  const PowerRecoveryPolicy({
    required this.revision,
    required this.sourceId,
    required this.criticalRuntimeSeconds,
    required this.restoreStableSeconds,
    required this.targets,
    required this.configuredAt,
  });

  factory PowerRecoveryPolicy.fromJson(Object? raw) {
    final json = serverObject(raw);
    _keys(json, const {
      'contractVersion',
      'revision',
      'sourceId',
      'criticalRuntimeSeconds',
      'restoreStableSeconds',
      'targets',
      'configuredAt',
    });
    final revision = json['revision'];
    final source = json['sourceId'];
    final critical = json['criticalRuntimeSeconds'];
    final stable = json['restoreStableSeconds'];
    final rawTargets = json['targets'];
    if (json['contractVersion'] != 1 ||
        revision is! int ||
        revision < 1 ||
        source is! String ||
        !RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(source) ||
        critical is! int ||
        critical < 60 ||
        critical > 3600 ||
        stable is! int ||
        stable < 30 ||
        stable > 3600 ||
        rawTargets is! List ||
        rawTargets.isEmpty ||
        rawTargets.length > 64) {
      throw const LarenorServerException('invalid_response');
    }
    return PowerRecoveryPolicy(
      revision: revision,
      sourceId: source,
      criticalRuntimeSeconds: critical,
      restoreStableSeconds: stable,
      targets: List.unmodifiable(rawTargets.map(PowerRecoveryTarget.fromJson)),
      configuredAt: _time(json['configuredAt']),
    );
  }

  final int revision;
  final String sourceId;
  final int criticalRuntimeSeconds;
  final int restoreStableSeconds;
  final List<PowerRecoveryTarget> targets;
  final DateTime configuredAt;
}

enum PowerStepState { queued, executing, succeeded, failed, skipped }

final class PowerRecoveryStep {
  const PowerRecoveryStep({
    required this.stepId,
    required this.sequence,
    required this.action,
    required this.targetId,
    required this.state,
    required this.resultCode,
    required this.updatedAt,
  });

  factory PowerRecoveryStep.fromJson(Object? raw) {
    final json = serverObject(raw);
    _keys(json, const {
      'stepId',
      'sequence',
      'action',
      'targetId',
      'targetKind',
      'state',
      'resultCode',
      'createdAt',
      'updatedAt',
    });
    final sequence = json['sequence'];
    final action = json['action'];
    final target = json['targetId'];
    final targetKind = json['targetKind'];
    final result = json['resultCode'];
    final state = switch (json['state']) {
      'queued' => PowerStepState.queued,
      'executing' => PowerStepState.executing,
      'succeeded' => PowerStepState.succeeded,
      'failed' => PowerStepState.failed,
      'skipped' => PowerStepState.skipped,
      _ => throw const LarenorServerException('invalid_response'),
    };
    final targeted = action == 'shutdownTarget' || action == 'startTarget';
    if (sequence is! int ||
        sequence < 1 ||
        action is! String ||
        !const {
          'holdNewWork',
          'drainActiveWork',
          'checkpointDatabase',
          'shutdownTarget',
          'startTarget',
          'releaseNewWork',
        }.contains(action) ||
        targeted != (target != null && targetKind != null) ||
        target != null && target is! String ||
        targetKind != null &&
            !const {
              'service',
              'proxmoxGuest',
              'networkDevice',
              'coreHost',
            }.contains(targetKind) ||
        result is! String ||
        !const {
          'pending',
          'completed',
          'no_active_work',
          'active_work_timeout',
          'checkpoint_failed',
          'effect_failed',
          'restore_disabled',
        }.contains(result)) {
      throw const LarenorServerException('invalid_response');
    }
    _time(json['createdAt']);
    return PowerRecoveryStep(
      stepId: _identity(json['stepId']),
      sequence: sequence,
      action: action,
      targetId: target == null ? null : _identity(target),
      state: state,
      resultCode: result,
      updatedAt: _time(json['updatedAt']),
    );
  }

  final String stepId;
  final int sequence;
  final String action;
  final String? targetId;
  final PowerStepState state;
  final String resultCode;
  final DateTime updatedAt;
}

enum PowerRunState {
  draining,
  shuttingDown,
  protected,
  restoring,
  completed,
  failed,
}

final class PowerRecoveryRun {
  const PowerRecoveryRun({
    required this.runId,
    required this.state,
    required this.gateHeld,
    required this.updatedAt,
    required this.failureCode,
    required this.steps,
  });

  factory PowerRecoveryRun.fromJson(Object? raw) {
    final json = serverObject(raw);
    _keys(json, const {
      'runId',
      'policyRevision',
      'triggerEventId',
      'state',
      'gateState',
      'createdAt',
      'updatedAt',
      'restoreEligibleAt',
      'failureCode',
      'steps',
    });
    final state = switch (json['state']) {
      'draining' => PowerRunState.draining,
      'shuttingDown' => PowerRunState.shuttingDown,
      'protected' => PowerRunState.protected,
      'restoring' => PowerRunState.restoring,
      'completed' => PowerRunState.completed,
      'failed' => PowerRunState.failed,
      _ => throw const LarenorServerException('invalid_response'),
    };
    final rawSteps = json['steps'];
    final failure = json['failureCode'];
    final restoreEligible = json['restoreEligibleAt'];
    if (!const {'open', 'held'}.contains(json['gateState']) ||
        rawSteps is! List ||
        rawSteps.length > 134 ||
        failure != null &&
            !const {
              'active_work_timeout',
              'checkpoint_failed',
              'effect_failed',
            }.contains(failure)) {
      throw const LarenorServerException('invalid_response');
    }
    _revision(json['policyRevision']);
    _identity(json['triggerEventId']);
    _time(json['createdAt']);
    if (restoreEligible != null) _time(restoreEligible);
    return PowerRecoveryRun(
      runId: _identity(json['runId']),
      state: state,
      gateHeld: json['gateState'] == 'held',
      updatedAt: _time(json['updatedAt']),
      failureCode: failure as String?,
      steps: List.unmodifiable(rawSteps.map(PowerRecoveryStep.fromJson)),
    );
  }

  final String runId;
  final PowerRunState state;
  final bool gateHeld;
  final DateTime updatedAt;
  final String? failureCode;
  final List<PowerRecoveryStep> steps;
}

final class PowerRecoveryStatus {
  const PowerRecoveryStatus({
    required this.policy,
    required this.sourceState,
    required this.gateHeld,
    required this.lastObservedAt,
    required this.activeRun,
    required this.recentRuns,
  });

  factory PowerRecoveryStatus.fromJson(Object? raw) {
    final json = serverObject(raw);
    _keys(json, const {
      'policy',
      'sourceState',
      'gateState',
      'lastSequence',
      'lastObservedAt',
      'activeRun',
      'recentRuns',
    });
    final source = json['sourceState'];
    final rawRuns = json['recentRuns'];
    final lastSequence = json['lastSequence'];
    if (!const {
          'unconfigured',
          'online',
          'onBattery',
          'lowBattery',
        }.contains(source) ||
        !const {'open', 'held'}.contains(json['gateState']) ||
        lastSequence is! int ||
        lastSequence < 0 ||
        rawRuns is! List ||
        rawRuns.length > 20) {
      throw const LarenorServerException('invalid_response');
    }
    return PowerRecoveryStatus(
      policy: json['policy'] == null
          ? null
          : PowerRecoveryPolicy.fromJson(json['policy']),
      sourceState: source as String,
      gateHeld: json['gateState'] == 'held',
      lastObservedAt: json['lastObservedAt'] == null
          ? null
          : _time(json['lastObservedAt']),
      activeRun: json['activeRun'] == null
          ? null
          : PowerRecoveryRun.fromJson(json['activeRun']),
      recentRuns: List.unmodifiable(rawRuns.map(PowerRecoveryRun.fromJson)),
    );
  }

  final PowerRecoveryPolicy? policy;
  final String sourceState;
  final bool gateHeld;
  final DateTime? lastObservedAt;
  final PowerRecoveryRun? activeRun;
  final List<PowerRecoveryRun> recentRuns;
}
