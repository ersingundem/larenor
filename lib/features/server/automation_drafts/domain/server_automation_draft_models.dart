import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<Object?, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) {
    _invalid();
  }
  return value;
}

String _action(Object? value) => switch (value) {
  'turn_on' || 'turn_off' => value as String,
  _ => _invalid(),
};

final class ServerAutomationRule {
  const ServerAutomationRule._({required this.id, required this.action});

  factory ServerAutomationRule.fromJson(
    Object? raw, {
    required ServerContext context,
    required String resourceId,
    required String expectedAction,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'ref',
      'action',
      'creatorId',
      'resourceRevision',
      'aclRevision',
      'bindingId',
      'bindingRevision',
      'serviceId',
      'serviceRevision',
    });
    final ref = _object(value['ref'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    final action = _action(value['action']);
    if (value['schemaVersion'] != 1 ||
        value['revision'] != 1 ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != context.coreId ||
        ref['homeId'] != context.homeId ||
        ref['kind'] != 'resource' ||
        ref['id'] != resourceId ||
        action != expectedAction) {
      _invalid();
    }
    _id(value['creatorId']);
    _id(value['bindingId']);
    _id(value['serviceId']);
    _revision(value['resourceRevision']);
    _revision(value['aclRevision']);
    _revision(value['bindingRevision']);
    _revision(value['serviceRevision']);
    return ServerAutomationRule._(id: _id(value['id']), action: action);
  }

  final String id, action;
}

final class ServerAutomationDraft {
  const ServerAutomationDraft._({
    required this.id,
    required this.revision,
    required this.state,
    required this.catalogVersion,
    required this.resourceId,
    required this.action,
    required this.steps,
    required this.sideEffects,
    required this.expiresAt,
    required this.expired,
    required this.requiresExplicitConfirmation,
    required this.rule,
  });

  factory ServerAutomationDraft.fromJson(
    Object? raw, {
    required ServerContext context,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'state',
      'catalogVersion',
      'target',
      'action',
      'steps',
      'sideEffects',
      'expiresAt',
      'expired',
      'requiresExplicitConfirmation',
      'deviceCommandAvailable',
      'rule',
    });
    final target = _object(value['target'], {'resourceId'});
    final resourceId = _id(target['resourceId']);
    final action = _action(value['action']);
    final state = switch (value['state']) {
      'draft' || 'activated' => value['state'] as String,
      _ => _invalid(),
    };
    final steps = value['steps'];
    final sideEffects = value['sideEffects'];
    final expiresAt = value['expiresAt'];
    if (value['schemaVersion'] != 1 ||
        value['catalogVersion'] != 'ha-switch-actions-v1' ||
        steps is! List ||
        steps.length != 2 ||
        steps[0] != 'validate_current_target' ||
        steps[1] != 'create_inert_rule' ||
        sideEffects is! List ||
        sideEffects.length != 2 ||
        sideEffects[0] != 'creates_automation_rule' ||
        sideEffects[1] != 'does_not_execute_device' ||
        expiresAt is! num ||
        !expiresAt.isFinite ||
        expiresAt < 0 ||
        value['expired'] is! bool ||
        value['requiresExplicitConfirmation'] is! bool ||
        value['deviceCommandAvailable'] != false ||
        (state == 'draft') != (value['requiresExplicitConfirmation'] == true) ||
        (state == 'draft') != (value['rule'] == null)) {
      _invalid();
    }
    final rule = value['rule'] == null
        ? null
        : ServerAutomationRule.fromJson(
            value['rule'],
            context: context,
            resourceId: resourceId,
            expectedAction: action,
          );
    return ServerAutomationDraft._(
      id: _id(value['id']),
      revision: _revision(value['revision']),
      state: state,
      catalogVersion: value['catalogVersion'] as String,
      resourceId: resourceId,
      action: action,
      steps: List.unmodifiable(steps.cast<String>()),
      sideEffects: List.unmodifiable(sideEffects.cast<String>()),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (expiresAt * 1000).round(),
        isUtc: true,
      ),
      expired: value['expired'] as bool,
      requiresExplicitConfirmation:
          value['requiresExplicitConfirmation'] as bool,
      rule: rule,
    );
  }

  final String id, state, catalogVersion, resourceId, action;
  final int revision;
  final List<String> steps, sideEffects;
  final DateTime expiresAt;
  final bool expired, requiresExplicitConfirmation;
  final ServerAutomationRule? rule;
  bool get activated => state == 'activated';
}

final class ServerAutomationDraftSelection {
  const ServerAutomationDraftSelection({
    required this.draft,
    required this.targetLabel,
  });
  final ServerAutomationDraft draft;
  final String targetLabel;
}
