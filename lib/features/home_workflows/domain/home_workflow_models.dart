import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<Object?, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _identity(Object? value) {
  if (value is! String ||
      value.length != 32 ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(
  Object? value, {
  int minimum = 1,
  int maximum = 9223372036854775807,
}) {
  if (value is! int || value < minimum || value > maximum) _invalid();
  return value;
}

DateTime _timestamp(Object? value) {
  if (value is! String ||
      value.length > 40 ||
      !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(value)) {
    _invalid();
  }
  final result = DateTime.tryParse(value);
  if (result == null || !result.isUtc) _invalid();
  return result;
}

enum HomeWorkflowAction { turnOn, turnOff }

extension HomeWorkflowActionWire on HomeWorkflowAction {
  String get wire => switch (this) {
    HomeWorkflowAction.turnOn => 'turn_on',
    HomeWorkflowAction.turnOff => 'turn_off',
  };
}

enum HomeWorkflowState {
  waitingDecision,
  running,
  reconciliationRequired,
  completed,
  failed,
  cancelled,
  timedOut,
}

enum HomeWorkflowDecisionRequired { approveEffect, reconcileEffect }

enum HomeWorkflowEffectState { notStarted, accepted, rejected, unknown }

enum HomeWorkflowReconciliationResult { none, effectApplied, effectNotApplied }

enum HomeWorkflowDecision { approve, cancel, effectApplied, effectNotApplied }

extension HomeWorkflowDecisionWire on HomeWorkflowDecision {
  String get wire => switch (this) {
    HomeWorkflowDecision.approve => 'approve',
    HomeWorkflowDecision.cancel => 'cancel',
    HomeWorkflowDecision.effectApplied => 'effect_applied',
    HomeWorkflowDecision.effectNotApplied => 'effect_not_applied',
  };
}

final class HomeWorkflowTarget {
  const HomeWorkflowTarget._({
    required this.context,
    required this.resourceId,
    required this.action,
    required this.bindingRevision,
    required this.resourceRevision,
    required this.aclRevision,
  });

  factory HomeWorkflowTarget.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
  }) {
    final value = _object(raw, {
      'kind',
      'resource',
      'action',
      'bindingRevision',
      'resourceRevision',
      'aclRevision',
    });
    if (value['kind'] != 'home_assistant_switch') _invalid();
    final resource = _object(value['resource'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    final context = ServerContext.fromJson({
      'schemaVersion': resource['schemaVersion'],
      'coreId': resource['coreId'],
      'homeId': resource['homeId'],
    });
    if (context != expectedContext || resource['kind'] != 'resource') {
      _invalid();
    }
    final action = switch (value['action']) {
      'turn_on' => HomeWorkflowAction.turnOn,
      'turn_off' => HomeWorkflowAction.turnOff,
      _ => _invalid(),
    };
    return HomeWorkflowTarget._(
      context: context,
      resourceId: _identity(resource['id']),
      action: action,
      bindingRevision: _revision(value['bindingRevision']),
      resourceRevision: _revision(value['resourceRevision']),
      aclRevision: _revision(value['aclRevision']),
    );
  }

  final ServerContext context;
  final String resourceId;
  final HomeWorkflowAction action;
  final int bindingRevision, resourceRevision, aclRevision;
}

final class HomeWorkflow {
  const HomeWorkflow._({
    required this.context,
    required this.id,
    required this.revision,
    required this.requestId,
    required this.creatorId,
    required this.title,
    required this.target,
    required this.state,
    required this.decisionRequired,
    required this.attempt,
    required this.stepRequestId,
    required this.effectState,
    required this.reconciliationResult,
    required this.cancelRequested,
    required this.deadlineAt,
    required this.createdAt,
    required this.updatedAt,
  });

  static const maximumRecords = 256;
  static const maximumPageSize = 50;
  static const maximumTitleCharacters = 80;
  static const maximumAttempts = 3;

  factory HomeWorkflow.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'requestId',
      'scope',
      'creatorId',
      'title',
      'target',
      'state',
      'decisionRequired',
      'attempt',
      'stepRequestId',
      'effectState',
      'reconciliationResult',
      'cancelRequested',
      'deadlineAt',
      'createdAt',
      'updatedAt',
    });
    if (value['schemaVersion'] != 1 || value['cancelRequested'] is! bool) {
      _invalid();
    }
    final context = ServerContext.fromJson(value['scope']);
    if (context != expectedContext) _invalid();
    final title = value['title'];
    if (title is! String ||
        title.runes.isEmpty ||
        title.runes.length > maximumTitleCharacters ||
        title != title.trim() ||
        title.runes.any((rune) => rune < 32 || rune == 127)) {
      _invalid();
    }
    final state = switch (value['state']) {
      'waiting_decision' => HomeWorkflowState.waitingDecision,
      'running' => HomeWorkflowState.running,
      'reconciliation_required' => HomeWorkflowState.reconciliationRequired,
      'completed' => HomeWorkflowState.completed,
      'failed' => HomeWorkflowState.failed,
      'cancelled' => HomeWorkflowState.cancelled,
      'timed_out' => HomeWorkflowState.timedOut,
      _ => _invalid(),
    };
    final decision = switch (value['decisionRequired']) {
      null => null,
      'approve_effect' => HomeWorkflowDecisionRequired.approveEffect,
      'reconcile_effect' => HomeWorkflowDecisionRequired.reconcileEffect,
      _ => _invalid(),
    };
    if (state == HomeWorkflowState.waitingDecision &&
            decision != HomeWorkflowDecisionRequired.approveEffect ||
        state == HomeWorkflowState.reconciliationRequired &&
            decision != HomeWorkflowDecisionRequired.reconcileEffect ||
        state != HomeWorkflowState.waitingDecision &&
            state != HomeWorkflowState.reconciliationRequired &&
            decision != null) {
      _invalid();
    }
    final effect = switch (value['effectState']) {
      'not_started' => HomeWorkflowEffectState.notStarted,
      'accepted' => HomeWorkflowEffectState.accepted,
      'rejected' => HomeWorkflowEffectState.rejected,
      'unknown' => HomeWorkflowEffectState.unknown,
      _ => _invalid(),
    };
    final reconciliation = switch (value['reconciliationResult']) {
      'none' => HomeWorkflowReconciliationResult.none,
      'effect_applied' => HomeWorkflowReconciliationResult.effectApplied,
      'effect_not_applied' => HomeWorkflowReconciliationResult.effectNotApplied,
      _ => _invalid(),
    };
    final created = _timestamp(value['createdAt']);
    final updated = _timestamp(value['updatedAt']);
    final deadline = _timestamp(value['deadlineAt']);
    if (updated.isBefore(created) || deadline.isBefore(created)) _invalid();
    final step = value['stepRequestId'];
    if (step != null) _identity(step);
    return HomeWorkflow._(
      context: context,
      id: _identity(value['id']),
      revision: _revision(value['revision']),
      requestId: _identity(value['requestId']),
      creatorId: _identity(value['creatorId']),
      title: title,
      target: HomeWorkflowTarget.fromJson(
        value['target'],
        expectedContext: context,
      ),
      state: state,
      decisionRequired: decision,
      attempt: _revision(value['attempt'], maximum: maximumAttempts),
      stepRequestId: step as String?,
      effectState: effect,
      reconciliationResult: reconciliation,
      cancelRequested: value['cancelRequested'] as bool,
      deadlineAt: deadline,
      createdAt: created,
      updatedAt: updated,
    );
  }

  final ServerContext context;
  final String id, requestId, creatorId, title;
  final int revision, attempt;
  final HomeWorkflowTarget target;
  final HomeWorkflowState state;
  final HomeWorkflowDecisionRequired? decisionRequired;
  final String? stepRequestId;
  final HomeWorkflowEffectState effectState;
  final HomeWorkflowReconciliationResult reconciliationResult;
  final bool cancelRequested;
  final DateTime deadlineAt, createdAt, updatedAt;

  bool get terminal => switch (state) {
    HomeWorkflowState.completed ||
    HomeWorkflowState.failed ||
    HomeWorkflowState.cancelled ||
    HomeWorkflowState.timedOut => true,
    _ => false,
  };
}

final class HomeWorkflowPage {
  const HomeWorkflowPage._(this.workflows, this.nextBefore);

  factory HomeWorkflowPage.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    int limit = HomeWorkflow.maximumPageSize,
  }) {
    if (limit < 1 || limit > HomeWorkflow.maximumPageSize) _invalid();
    final value = _object(raw, {'schemaVersion', 'workflows', 'nextBefore'});
    if (value['schemaVersion'] != 1) _invalid();
    final rawWorkflows = value['workflows'];
    if (rawWorkflows is! List || rawWorkflows.length > limit) _invalid();
    final workflows = <HomeWorkflow>[];
    final ids = <String>{};
    for (final rawWorkflow in rawWorkflows) {
      final workflow = HomeWorkflow.fromJson(
        rawWorkflow,
        expectedContext: expectedContext,
      );
      if (!ids.add(workflow.id)) _invalid();
      workflows.add(workflow);
    }
    final next = value['nextBefore'] == null
        ? null
        : _identity(value['nextBefore']);
    if (next != null && workflows.isEmpty) _invalid();
    return HomeWorkflowPage._(List.unmodifiable(workflows), next);
  }

  final List<HomeWorkflow> workflows;
  final String? nextBefore;
}
