import '../../home_resources/domain/home_resource_models.dart';
import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');
Map _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _id(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(value) ||
      value.length != 32) {
    _invalid();
  }
  return value;
}

int _integer(Object? value, {int min = 1, int max = 9223372036854775807}) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

void _schema(Object? value) {
  if (value is! int || value != 1) _invalid();
}

void _ref(Object? value, HomeResourceRecord target) {
  final ref = _object(value, {
    'schemaVersion',
    'coreId',
    'homeId',
    'kind',
    'id',
  });
  _schema(ref['schemaVersion']);
  if (target.kind != HomeResourceKind.resource ||
      ref['kind'] != 'resource' ||
      ref['id'] != target.id ||
      ref['coreId'] != target.context.coreId ||
      ref['homeId'] != target.context.homeId) {
    _invalid();
  }
}

enum CoreHaSwitchState { on, off, unavailable }

final class CoreHaProjection {
  const CoreHaProjection._(
    this.kind,
    this.rawState,
    this.switchState,
    this.commandAvailable,
  );
  final String kind, rawState;
  final CoreHaSwitchState? switchState;
  final bool commandAvailable;
  CoreHaSwitchState get state => switchState ?? _invalid();
  factory CoreHaProjection.fromJson(Object? raw) {
    final value = _object(raw, {'kind', 'state', 'commandAvailable'});
    final kind = value['kind'], state = value['state'];
    if (kind is! String ||
        !_coreHaDomain(kind) ||
        state is! String ||
        !_coreHaState(state) ||
        value['commandAvailable'] is! bool) {
      _invalid();
    }
    final switchState = kind == 'switch'
        ? switch (state) {
            'on' => CoreHaSwitchState.on,
            'off' => CoreHaSwitchState.off,
            'unavailable' => CoreHaSwitchState.unavailable,
            _ => _invalid(),
          }
        : null;
    final commandAvailable = value['commandAvailable'] as bool;
    if (kind != 'switch' && commandAvailable) _invalid();
    return CoreHaProjection._(kind, state, switchState, commandAvailable);
  }
  @override
  String toString() => 'CoreHaProjection';
}

enum CoreHaCommandAction { turnOn, turnOff }

enum CoreHaDispatchState { pending, accepted, rejected, unknown }

final class CoreHaCommandReceipt {
  const CoreHaCommandReceipt._({
    required this.requestId,
    required this.bindingId,
    required this.bindingRevision,
    required this.actorId,
    required this.action,
    required this.dispatchState,
    required this.providerAccepted,
    required this.observedProjection,
    required this.observationMatchesTarget,
    required this.createdAt,
    required this.completedAt,
  });
  final String requestId, bindingId, actorId;
  final int bindingRevision;
  final CoreHaCommandAction action;
  final CoreHaDispatchState dispatchState;
  final bool? providerAccepted, observationMatchesTarget;
  final CoreHaProjection? observedProjection;
  final DateTime createdAt;
  final DateTime? completedAt;

  factory CoreHaCommandReceipt.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'requestId',
      'ref',
      'bindingId',
      'bindingRevision',
      'actorId',
      'action',
      'dispatchState',
      'providerAccepted',
      'observedProjection',
      'observationMatchesTarget',
      'causalityVerified',
      'createdAt',
      'completedAt',
    });
    _schema(value['schemaVersion']);
    _ref(value['ref'], target);
    if (value['causalityVerified'] != false ||
        value['providerAccepted'] != null &&
            value['providerAccepted'] is! bool ||
        value['observationMatchesTarget'] != null &&
            value['observationMatchesTarget'] is! bool) {
      _invalid();
    }
    final action = switch (value['action']) {
      'turn_on' => CoreHaCommandAction.turnOn,
      'turn_off' => CoreHaCommandAction.turnOff,
      _ => _invalid(),
    };
    final dispatch = switch (value['dispatchState']) {
      'pending' => CoreHaDispatchState.pending,
      'accepted' => CoreHaDispatchState.accepted,
      'rejected' => CoreHaDispatchState.rejected,
      'unknown' => CoreHaDispatchState.unknown,
      _ => _invalid(),
    };
    final created = _coreHaTimestamp(value['createdAt']),
        completed = value['completedAt'] == null
            ? null
            : _coreHaTimestamp(value['completedAt']),
        provider = value['providerAccepted'] as bool?,
        observed = value['observedProjection'] == null
            ? null
            : CoreHaProjection.fromJson(value['observedProjection']),
        matches = value['observationMatchesTarget'] as bool?;
    final targetState = action == CoreHaCommandAction.turnOn
        ? CoreHaSwitchState.on
        : CoreHaSwitchState.off;
    if (completed != null && completed.isBefore(created) ||
        dispatch == CoreHaDispatchState.pending &&
            (provider != null ||
                observed != null ||
                matches != null ||
                completed != null) ||
        dispatch == CoreHaDispatchState.accepted && provider != true ||
        dispatch == CoreHaDispatchState.rejected && provider != false ||
        dispatch == CoreHaDispatchState.unknown && provider != null ||
        observed == null && matches != null ||
        observed != null && matches == null ||
        observed != null && matches != (observed.switchState == targetState) ||
        dispatch != CoreHaDispatchState.pending && completed == null) {
      _invalid();
    }
    return CoreHaCommandReceipt._(
      requestId: _id(value['requestId']),
      bindingId: _id(value['bindingId']),
      bindingRevision: _integer(value['bindingRevision']),
      actorId: _id(value['actorId']),
      action: action,
      dispatchState: dispatch,
      providerAccepted: provider,
      observedProjection: observed,
      observationMatchesTarget: matches,
      createdAt: created,
      completedAt: completed,
    );
  }

  @override
  String toString() => 'CoreHaCommandReceipt';
}

DateTime _coreHaTimestamp(Object? value) {
  if (value is! String ||
      value.length > 40 ||
      !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(value)) {
    _invalid();
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) _invalid();
  return parsed;
}

final class CoreHaSnapshot {
  const CoreHaSnapshot._(
    this.bindingId,
    this.bindingRevision,
    this.resourceRevision,
    this.aclRevision,
    this.serviceRevision,
    this.observedAt,
    this.remainingTtlMs,
    this.projection,
  );
  final String bindingId;
  final int bindingRevision, resourceRevision, aclRevision, serviceRevision;
  final DateTime observedAt;
  final int remainingTtlMs;
  final CoreHaProjection projection;
  factory CoreHaSnapshot.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'ref',
      'bindingId',
      'bindingRevision',
      'resourceRevision',
      'aclRevision',
      'serviceRevision',
      'observedAt',
      'remainingTtlMs',
      'projection',
    });
    _schema(value['schemaVersion']);
    _ref(value['ref'], target);
    final date = _coreHaTimestamp(value['observedAt']);
    return CoreHaSnapshot._(
      _id(value['bindingId']),
      _integer(value['bindingRevision']),
      _integer(value['resourceRevision'], min: target.revision),
      _integer(value['aclRevision'], min: target.aclRevision),
      _integer(value['serviceRevision']),
      date,
      _integer(value['remainingTtlMs'], min: 0, max: 5000),
      CoreHaProjection.fromJson(value['projection']),
    );
  }
  @override
  String toString() => 'CoreHaSnapshot';
}

final class CoreHaBinding {
  const CoreHaBinding._(
    this.id,
    this.revision,
    this.target,
    this.serviceId,
    this.serviceRevision,
    this.entityId,
  );
  final String id, serviceId, entityId;
  final int revision, serviceRevision;
  final HomeResourceRecord target;
  factory CoreHaBinding.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'ref',
      'serviceId',
      'serviceRevision',
      'entityId',
    });
    _schema(value['schemaVersion']);
    _ref(value['ref'], target);
    final entity = value['entityId'];
    if (entity is! String || !coreHaEntityId(entity)) _invalid();
    return CoreHaBinding._(
      _id(value['id']),
      _integer(value['revision']),
      target,
      _id(value['serviceId']),
      _integer(value['serviceRevision']),
      entity,
    );
  }
  bool sameBinding(CoreHaBinding other) =>
      id == other.id &&
      revision == other.revision &&
      target.context == other.target.context &&
      target.id == other.target.id &&
      serviceId == other.serviceId &&
      serviceRevision == other.serviceRevision &&
      entityId == other.entityId;
  @override
  String toString() => 'CoreHaBinding';
}

final class CoreHaPreview {
  const CoreHaPreview._(
    this.id,
    this.expiresInMs,
    this.binding,
    this.projection,
  );
  final String id;
  final int expiresInMs;
  final CoreHaBinding binding;
  final CoreHaProjection projection;
  factory CoreHaPreview.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {'id', 'expiresInMs', 'binding', 'projection'});
    return CoreHaPreview._(
      _id(value['id']),
      _integer(value['expiresInMs'], max: 60000),
      CoreHaBinding.fromJson(value['binding'], target: target),
      CoreHaProjection.fromJson(value['projection']),
    );
  }
  @override
  String toString() => 'CoreHaPreview';
}

bool coreHaEntityId(String value) =>
    value.length <= 128 &&
    RegExp(r'^[a-z0-9_]{1,64}\.[a-z0-9_]+$').hasMatch(value) &&
    !value.endsWith('\n');

bool coreHaSwitchEntityId(String value) =>
    value.startsWith('switch.') && coreHaEntityId(value);

bool _coreHaDomain(String value) =>
    value.length <= 64 && RegExp(r'^[a-z0-9_]+$').hasMatch(value);

bool _coreHaState(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    !value.runes.any(
      (rune) =>
          rune < 32 ||
          rune >= 127 && rune <= 159 ||
          rune >= 0xd800 && rune <= 0xdfff ||
          rune >= 0x200b && rune <= 0x200f ||
          rune >= 0x202a && rune <= 0x202e ||
          rune >= 0x2060 && rune <= 0x206f ||
          rune == 0xfeff,
    );
