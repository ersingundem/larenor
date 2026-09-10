Never _invalid() => throw const FormatException('invalid_response');

enum ProxmoxPowerAction { start, shutdown, stop, reboot, suspend, resume }

enum ProxmoxPowerRisk { low, moderate, high }

enum ProxmoxGuestKind { qemu, lxc }

enum ProxmoxGuestState { running, stopped, suspended }

enum ProxmoxPowerReceiptState {
  accepted,
  executing,
  succeeded,
  failed,
  cancelled,
  unknown,
}

Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _identity(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) _invalid();
  return value;
}

double _timestamp(Object? value) {
  if (value is! num || !value.isFinite || value < 0) _invalid();
  return value.toDouble();
}

T _enum<T extends Enum>(Object? value, List<T> values) {
  if (value is! String) _invalid();
  return values.where((item) => item.name == value).firstOrNull ?? _invalid();
}

final class ProxmoxPowerTarget {
  const ProxmoxPowerTarget({
    required this.coreId,
    required this.homeId,
    required this.resourceId,
    required this.userRevision,
    required this.resourceRevision,
    required this.aclRevision,
    required this.bindingId,
    required this.bindingRevision,
    required this.serviceId,
    required this.serviceRevision,
    required this.guestKind,
    required this.node,
    required this.guestId,
    required this.currentState,
    required this.statusRevision,
    required this.allowedActions,
  });

  final String coreId, homeId, resourceId, bindingId, serviceId;
  final int userRevision, resourceRevision, aclRevision;
  final int bindingRevision, serviceRevision, statusRevision;
  final ProxmoxGuestKind guestKind;
  final String node;
  final int guestId;
  final ProxmoxGuestState currentState;
  final Set<ProxmoxPowerAction> allowedActions;

  void validate() {
    for (final id in [coreId, homeId, resourceId]) {
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
        throw ArgumentError.value(id, 'identity');
      }
    }
    for (final id in [bindingId, serviceId]) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
        throw ArgumentError.value(id, 'binding');
      }
    }
    if (!RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$')
            .hasMatch(node) ||
        guestId < 1 ||
        guestId > 999999999) {
      throw ArgumentError.value((node, guestId), 'guest');
    }
    for (final value in [
      userRevision,
      resourceRevision,
      aclRevision,
      bindingRevision,
      serviceRevision,
      statusRevision,
    ]) {
      if (value < 1 || value > 9223372036854775807) {
        throw ArgumentError.value(value, 'revision');
      }
    }
    final expected = switch (currentState) {
      ProxmoxGuestState.running => const {
        ProxmoxPowerAction.shutdown,
        ProxmoxPowerAction.stop,
        ProxmoxPowerAction.reboot,
        ProxmoxPowerAction.suspend,
      },
      ProxmoxGuestState.stopped => const {ProxmoxPowerAction.start},
      ProxmoxGuestState.suspended => const {ProxmoxPowerAction.resume},
    };
    if (allowedActions.isEmpty ||
        allowedActions.length != expected.length ||
        !allowedActions.containsAll(expected)) {
      throw ArgumentError.value(allowedActions, 'allowedActions');
    }
  }

  ProxmoxPowerTarget copyWith({String? bindingId}) {
    final value = ProxmoxPowerTarget(
      coreId: coreId,
      homeId: homeId,
      resourceId: resourceId,
      userRevision: userRevision,
      resourceRevision: resourceRevision,
      aclRevision: aclRevision,
      bindingId: bindingId ?? this.bindingId,
      bindingRevision: bindingRevision,
      serviceId: serviceId,
      serviceRevision: serviceRevision,
      guestKind: guestKind,
      node: node,
      guestId: guestId,
      currentState: currentState,
      statusRevision: statusRevision,
      allowedActions: allowedActions,
    );
    value.validate();
    return value;
  }
}

final class PowerPreview {
  const PowerPreview._({
    required this.id,
    required this.requestId,
    required this.action,
    required this.risk,
    required this.requiresSecondConfirmation,
    required this.guestKind,
    required this.currentState,
    required this.expectedResultState,
    required this.expiresAt,
  });

  factory PowerPreview.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'requestId',
      'action',
      'riskClass',
      'requiresSecondConfirmation',
      'guestKind',
      'currentState',
      'expectedResultState',
      'expiresAt',
    });
    if (value['schemaVersion'] != 1 ||
        value['requiresSecondConfirmation'] is! bool) {
      _invalid();
    }
    final risk = _enum(value['riskClass'], ProxmoxPowerRisk.values);
    final second = value['requiresSecondConfirmation'] as bool;
    if (second != (risk == ProxmoxPowerRisk.high)) _invalid();
    return PowerPreview._(
      id: _identity(value['id']),
      requestId: _identity(value['requestId']),
      action: _enum(value['action'], ProxmoxPowerAction.values),
      risk: risk,
      requiresSecondConfirmation: second,
      guestKind: _enum(value['guestKind'], ProxmoxGuestKind.values),
      currentState: _enum(value['currentState'], ProxmoxGuestState.values),
      expectedResultState: _enum(
        value['expectedResultState'],
        ProxmoxGuestState.values,
      ),
      expiresAt: _timestamp(value['expiresAt']),
    );
  }

  final String id, requestId;
  final ProxmoxPowerAction action;
  final ProxmoxPowerRisk risk;
  final bool requiresSecondConfirmation;
  final ProxmoxGuestKind guestKind;
  final ProxmoxGuestState currentState, expectedResultState;
  final double expiresAt;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'requestId': requestId,
    'action': action.name,
    'riskClass': risk.name,
    'requiresSecondConfirmation': requiresSecondConfirmation,
    'guestKind': guestKind.name,
    'currentState': currentState.name,
    'expectedResultState': expectedResultState.name,
    'expiresAt': expiresAt,
  };
}

final class PowerReceipt {
  const PowerReceipt._({
    required this.requestId,
    required this.action,
    required this.state,
    required this.resultCode,
    required this.guestState,
    required this.statusRevision,
    required this.causalityVerified,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PowerReceipt.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'requestId',
      'action',
      'state',
      'resultCode',
      'guestState',
      'statusRevision',
      'causalityVerified',
      'createdAt',
      'updatedAt',
    });
    if (value['schemaVersion'] != 1 || value['causalityVerified'] is! bool) {
      _invalid();
    }
    final state = _enum(value['state'], ProxmoxPowerReceiptState.values);
    final code = value['resultCode'];
    const allowed = {
      'accepted',
      'executing',
      'completed',
      'effect_failed',
      'cancelled',
      'outcome_uncertain',
    };
    if (code is! String || !allowed.contains(code)) _invalid();
    final expected = switch (state) {
      ProxmoxPowerReceiptState.accepted => 'accepted',
      ProxmoxPowerReceiptState.executing => 'executing',
      ProxmoxPowerReceiptState.succeeded => 'completed',
      ProxmoxPowerReceiptState.failed => 'effect_failed',
      ProxmoxPowerReceiptState.cancelled => 'cancelled',
      ProxmoxPowerReceiptState.unknown => 'outcome_uncertain',
    };
    if (code != expected) _invalid();
    final created = _timestamp(value['createdAt']);
    final updated = _timestamp(value['updatedAt']);
    if (updated < created) _invalid();
    return PowerReceipt._(
      requestId: _identity(value['requestId']),
      action: _enum(value['action'], ProxmoxPowerAction.values),
      state: state,
      resultCode: code,
      guestState: _enum(value['guestState'], ProxmoxGuestState.values),
      statusRevision: _revision(value['statusRevision']),
      causalityVerified: value['causalityVerified'] as bool,
      createdAt: created,
      updatedAt: updated,
    );
  }

  final String requestId, resultCode;
  final ProxmoxPowerAction action;
  final ProxmoxPowerReceiptState state;
  final ProxmoxGuestState guestState;
  final int statusRevision;
  final bool causalityVerified;
  final double createdAt, updatedAt;
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'requestId': requestId,
    'action': action.name,
    'state': state.name,
    'resultCode': resultCode,
    'guestState': guestState.name,
    'statusRevision': statusRevision,
    'causalityVerified': causalityVerified,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}
