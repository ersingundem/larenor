import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

List<Object?> _list(Object? value, int min, int max) {
  if (value is! List || value.length < min || value.length > max) _invalid();
  return value.cast<Object?>();
}

String _id(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 128 ||
      !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _identity(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _label(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 80 ||
      value.runes.any((rune) => rune < 32 || rune == 127)) {
    _invalid();
  }
  return value;
}

String _state(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 255 ||
      value.runes.any((rune) => rune < 32 || rune == 127)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) _invalid();
  return value;
}

void _schema(Object? value) {
  if (value != 1) _invalid();
}

double _coordinate(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value > 1) _invalid();
  return value.toDouble();
}

@immutable
final class FloorPlanPoint {
  const FloorPlanPoint(this.x, this.y);
  factory FloorPlanPoint.fromJson(Object? value) {
    final json = _object(value, const {'x', 'y'});
    return FloorPlanPoint(_coordinate(json['x']), _coordinate(json['y']));
  }
  final double x, y;
}

@immutable
final class FloorPlanFloor {
  const FloorPlanFloor(this.id, this.label, this.order);
  factory FloorPlanFloor.fromJson(Object? value) {
    final json = _object(value, const {'floorId', 'label', 'order'});
    final order = json['order'];
    if (order is! int || order < 0 || order > 7) _invalid();
    return FloorPlanFloor(_id(json['floorId']), _label(json['label']), order);
  }
  final String id, label;
  final int order;
}

@immutable
final class FloorPlanRoom {
  const FloorPlanRoom(this.id, this.floorId, this.label, this.polygon);
  factory FloorPlanRoom.fromJson(Object? value) {
    final json = _object(value, const {
      'roomId',
      'floorId',
      'label',
      'polygon',
    });
    return FloorPlanRoom(
      _id(json['roomId']),
      _id(json['floorId']),
      _label(json['label']),
      List.unmodifiable(
        _list(json['polygon'], 3, 64).map(FloorPlanPoint.fromJson),
      ),
    );
  }
  final String id, floorId, label;
  final List<FloorPlanPoint> polygon;
}

@immutable
final class FloorPlanAnchor {
  const FloorPlanAnchor({
    required this.id,
    required this.roomId,
    required this.targetKind,
    required this.targetId,
    required this.targetRevision,
    required this.x,
    required this.y,
  });
  factory FloorPlanAnchor.fromJson(Object? value) {
    final json = _object(value, const {
      'anchorId',
      'roomId',
      'targetKind',
      'targetId',
      'targetRevision',
      'x',
      'y',
      'rotation',
    });
    final kind = json['targetKind'];
    final rotation = json['rotation'];
    if ((kind != 'entity' && kind != 'resource') ||
        rotation is! num ||
        !rotation.isFinite ||
        rotation < -360 ||
        rotation > 360) {
      _invalid();
    }
    return FloorPlanAnchor(
      id: _id(json['anchorId']),
      roomId: _id(json['roomId']),
      targetKind: kind! as String,
      targetId: _id(json['targetId']),
      targetRevision: _revision(json['targetRevision']),
      x: _coordinate(json['x']),
      y: _coordinate(json['y']),
    );
  }
  final String id, roomId, targetKind, targetId;
  final int targetRevision;
  final double x, y;
}

@immutable
final class FloorPlanVector {
  const FloorPlanVector(this.id, this.floorId, this.kind, this.points);
  factory FloorPlanVector.fromJson(Object? value) {
    final json = _object(value, const {'shapeId', 'floorId', 'kind', 'points'});
    return FloorPlanVector(
      _id(json['shapeId']),
      _id(json['floorId']),
      _id(json['kind']),
      List.unmodifiable(
        _list(json['points'], 2, 128).map(FloorPlanPoint.fromJson),
      ),
    );
  }
  final String id, floorId, kind;
  final List<FloorPlanPoint> points;
}

enum FloorPlanProjectionStatus { live, stale, unavailable }

enum FloorPlanAction { turnOn, turnOff }

@immutable
final class FloorPlanActionCapability {
  const FloorPlanActionCapability._({
    required this.actions,
    this.resourceId,
    this.resourceRevision,
    this.aclRevision,
    this.bindingId,
    this.bindingRevision,
    this.serviceRevision,
  });

  factory FloorPlanActionCapability.fromJson(Object? value) {
    final json = _object(value, const {
      'kind',
      'actions',
      'resourceId',
      'resourceRevision',
      'aclRevision',
      'bindingId',
      'bindingRevision',
      'serviceRevision',
    });
    final actions = _list(json['actions'], 0, 2);
    if (json['kind'] == 'none') {
      if (actions.isNotEmpty ||
          json.entries
              .where((entry) => !{'kind', 'actions'}.contains(entry.key))
              .any((entry) => entry.value != null)) {
        _invalid();
      }
      return const FloorPlanActionCapability._(actions: {});
    }
    if (json['kind'] != 'home_assistant.switch' ||
        actions.length != 2 ||
        actions[0] != 'turn_on' ||
        actions[1] != 'turn_off') {
      _invalid();
    }
    return FloorPlanActionCapability._(
      actions: const {FloorPlanAction.turnOn, FloorPlanAction.turnOff},
      resourceId: _identity(json['resourceId']),
      resourceRevision: _revision(json['resourceRevision']),
      aclRevision: _revision(json['aclRevision']),
      bindingId: _identity(json['bindingId']),
      bindingRevision: _revision(json['bindingRevision']),
      serviceRevision: _revision(json['serviceRevision']),
    );
  }

  final Set<FloorPlanAction> actions;
  final String? resourceId, bindingId;
  final int? resourceRevision;
  final int? aclRevision;
  final int? bindingRevision;
  final int? serviceRevision;
  bool get available => actions.isNotEmpty;
}

@immutable
final class FloorPlanAnchorProjection {
  const FloorPlanAnchorProjection._({
    required this.anchorId,
    required this.targetKind,
    required this.targetId,
    required this.targetRevision,
    required this.state,
    required this.status,
    required this.capability,
  });

  factory FloorPlanAnchorProjection.fromJson(Object? value) {
    final json = _object(value, const {
      'anchorId',
      'targetKind',
      'targetId',
      'targetRevision',
      'state',
      'status',
      'capability',
    });
    final kind = json['targetKind'];
    if (kind != 'entity' && kind != 'resource') _invalid();
    final status = switch (json['status']) {
      'live' => FloorPlanProjectionStatus.live,
      'stale' => FloorPlanProjectionStatus.stale,
      'unavailable' => FloorPlanProjectionStatus.unavailable,
      _ => _invalid(),
    };
    final capability = FloorPlanActionCapability.fromJson(json['capability']);
    if (status == FloorPlanProjectionStatus.unavailable &&
        capability.available) {
      _invalid();
    }
    return FloorPlanAnchorProjection._(
      anchorId: _id(json['anchorId']),
      targetKind: kind! as String,
      targetId: _id(json['targetId']),
      targetRevision: _revision(json['targetRevision']),
      state: _state(json['state']),
      status: status,
      capability: capability,
    );
  }

  final String anchorId, targetKind, targetId, state;
  final int targetRevision;
  final FloorPlanProjectionStatus status;
  final FloorPlanActionCapability capability;
}

@immutable
final class FloorPlanSnapshot {
  const FloorPlanSnapshot._({
    required this.context,
    required this.revision,
    required this.entityRegistryRevision,
    required this.resourceRevision,
    required this.grantRevision,
    required this.floors,
    required this.rooms,
    required this.anchors,
    required this.vectors,
    required this.projections,
    required this.projectionLimit,
    required this.projectionTruncated,
  });

  factory FloorPlanSnapshot.fromResponse(
    Object? value, {
    required ServerContext expected,
  }) {
    final json = _object(value, const {
      'schemaVersion',
      'layoutRevision',
      'entityRegistryRevision',
      'resourceRevision',
      'grantRevision',
      'layout',
      'projections',
      'projectionLimit',
      'projectionTruncated',
    });
    _schema(json['schemaVersion']);
    final layout = _object(json['layout'], const {
      'floors',
      'rooms',
      'anchors',
      'vectors',
    });
    final floors = _list(
      layout['floors'],
      1,
      8,
    ).map(FloorPlanFloor.fromJson).toList();
    final rooms = _list(
      layout['rooms'],
      1,
      128,
    ).map(FloorPlanRoom.fromJson).toList();
    final anchors = _list(
      layout['anchors'],
      0,
      512,
    ).map(FloorPlanAnchor.fromJson).toList();
    final vectors = _list(
      layout['vectors'],
      0,
      512,
    ).map(FloorPlanVector.fromJson).toList();
    final projections = _list(
      json['projections'],
      0,
      512,
    ).map(FloorPlanAnchorProjection.fromJson).toList();
    final floorIds = floors.map((item) => item.id).toSet();
    final roomIds = rooms.map((item) => item.id).toSet();
    final anchorIds = anchors.map((item) => item.id).toSet();
    final byAnchor = {for (final item in anchors) item.id: item};
    final projectionIds = projections.map((item) => item.anchorId).toSet();
    final projectionLimit = json['projectionLimit'];
    if (floorIds.length != floors.length ||
        roomIds.length != rooms.length ||
        rooms.any((item) => !floorIds.contains(item.floorId)) ||
        anchorIds.length != anchors.length ||
        anchors.any((item) => !roomIds.contains(item.roomId)) ||
        vectors.map((item) => item.id).toSet().length != vectors.length ||
        vectors.any((item) => !floorIds.contains(item.floorId)) ||
        projectionIds.length != projections.length ||
        projectionIds.length != anchorIds.length ||
        !projectionIds.containsAll(anchorIds) ||
        projections.any((item) {
          final anchor = byAnchor[item.anchorId];
          return anchor == null ||
              item.targetKind != anchor.targetKind ||
              item.targetId != anchor.targetId ||
              item.targetRevision != anchor.targetRevision;
        }) ||
        projectionLimit is! int ||
        projectionLimit < 1 ||
        projectionLimit > 512 ||
        json['projectionTruncated'] is! bool) {
      _invalid();
    }
    return FloorPlanSnapshot._(
      context: expected,
      revision: _revision(json['layoutRevision']),
      entityRegistryRevision: _revision(json['entityRegistryRevision']),
      resourceRevision: _revision(json['resourceRevision']),
      grantRevision: _revision(json['grantRevision']),
      floors: List.unmodifiable(floors),
      rooms: List.unmodifiable(rooms),
      anchors: List.unmodifiable(anchors),
      vectors: List.unmodifiable(vectors),
      projections: Map.unmodifiable({
        for (final projection in projections) projection.anchorId: projection,
      }),
      projectionLimit: projectionLimit,
      projectionTruncated: json['projectionTruncated'] as bool,
    );
  }

  final ServerContext context;
  final int revision, entityRegistryRevision, resourceRevision, grantRevision;
  final List<FloorPlanFloor> floors;
  final List<FloorPlanRoom> rooms;
  final List<FloorPlanAnchor> anchors;
  final List<FloorPlanVector> vectors;
  final Map<String, FloorPlanAnchorProjection> projections;
  final int projectionLimit;
  final bool projectionTruncated;
}

@immutable
final class FloorPlanActionRequest {
  const FloorPlanActionRequest._({
    required this.requestId,
    required this.anchorId,
    required this.action,
    required this.expectedLayoutRevision,
    required this.expectedEntityRegistryRevision,
    required this.expectedResourceRegistryRevision,
    required this.expectedGrantRevision,
    required this.expectedTargetRevision,
    required this.expectedResourceId,
    required this.expectedResourceRevision,
    required this.expectedAclRevision,
    required this.expectedBindingId,
    required this.expectedBindingRevision,
    required this.expectedServiceRevision,
  });

  factory FloorPlanActionRequest.forProjection({
    required String requestId,
    required FloorPlanSnapshot snapshot,
    required FloorPlanAnchorProjection projection,
    required FloorPlanAction action,
  }) {
    _identity(requestId);
    final capability = projection.capability;
    if (!capability.actions.contains(action)) _invalid();
    return FloorPlanActionRequest._(
      requestId: requestId,
      anchorId: projection.anchorId,
      action: action,
      expectedLayoutRevision: snapshot.revision,
      expectedEntityRegistryRevision: snapshot.entityRegistryRevision,
      expectedResourceRegistryRevision: snapshot.resourceRevision,
      expectedGrantRevision: snapshot.grantRevision,
      expectedTargetRevision: projection.targetRevision,
      expectedResourceId: capability.resourceId!,
      expectedResourceRevision: capability.resourceRevision!,
      expectedAclRevision: capability.aclRevision!,
      expectedBindingId: capability.bindingId!,
      expectedBindingRevision: capability.bindingRevision!,
      expectedServiceRevision: capability.serviceRevision!,
    );
  }

  final String requestId, anchorId, expectedResourceId, expectedBindingId;
  final FloorPlanAction action;
  final int expectedLayoutRevision;
  final int expectedEntityRegistryRevision;
  final int expectedResourceRegistryRevision;
  final int expectedGrantRevision;
  final int expectedTargetRevision;
  final int expectedResourceRevision;
  final int expectedAclRevision;
  final int expectedBindingRevision;
  final int expectedServiceRevision;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'requestId': requestId,
    'anchorId': anchorId,
    'action': switch (action) {
      FloorPlanAction.turnOn => 'turn_on',
      FloorPlanAction.turnOff => 'turn_off',
    },
    'expectedLayoutRevision': expectedLayoutRevision,
    'expectedEntityRegistryRevision': expectedEntityRegistryRevision,
    'expectedResourceRegistryRevision': expectedResourceRegistryRevision,
    'expectedGrantRevision': expectedGrantRevision,
    'expectedTargetRevision': expectedTargetRevision,
    'expectedResourceId': expectedResourceId,
    'expectedResourceRevision': expectedResourceRevision,
    'expectedAclRevision': expectedAclRevision,
    'expectedBindingId': expectedBindingId,
    'expectedBindingRevision': expectedBindingRevision,
    'expectedServiceRevision': expectedServiceRevision,
  };
}

enum FloorPlanDispatchState { pending, accepted, rejected, unknown }

@immutable
final class FloorPlanActionReceipt {
  const FloorPlanActionReceipt._(this.dispatchState);

  factory FloorPlanActionReceipt.fromResponse(
    Object? value, {
    required FloorPlanSnapshot expectedSnapshot,
    required FloorPlanActionRequest expectedRequest,
  }) {
    final root = _object(value, const {'receipt'});
    final receipt = _object(root['receipt'], const {
      'schemaVersion',
      'anchorId',
      'layoutRevision',
      'entityRegistryRevision',
      'resourceRevision',
      'grantRevision',
      'command',
    });
    _schema(receipt['schemaVersion']);
    if (receipt['anchorId'] != expectedRequest.anchorId ||
        receipt['layoutRevision'] != expectedSnapshot.revision ||
        receipt['entityRegistryRevision'] !=
            expectedSnapshot.entityRegistryRevision ||
        receipt['resourceRevision'] != expectedSnapshot.resourceRevision ||
        receipt['grantRevision'] != expectedSnapshot.grantRevision) {
      _invalid();
    }
    final command = _object(receipt['command'], const {
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
    _schema(command['schemaVersion']);
    final ref = _object(command['ref'], const {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    _schema(ref['schemaVersion']);
    final actionValue = switch (expectedRequest.action) {
      FloorPlanAction.turnOn => 'turn_on',
      FloorPlanAction.turnOff => 'turn_off',
    };
    if (command['requestId'] != expectedRequest.requestId ||
        ref['coreId'] != expectedSnapshot.context.coreId ||
        ref['homeId'] != expectedSnapshot.context.homeId ||
        ref['kind'] != 'resource' ||
        ref['id'] != expectedRequest.expectedResourceId ||
        command['bindingId'] != expectedRequest.expectedBindingId ||
        command['bindingRevision'] != expectedRequest.expectedBindingRevision ||
        command['action'] != actionValue ||
        command['causalityVerified'] != false) {
      _invalid();
    }
    _identity(command['actorId']);
    final dispatch = switch (command['dispatchState']) {
      'pending' => FloorPlanDispatchState.pending,
      'accepted' => FloorPlanDispatchState.accepted,
      'rejected' => FloorPlanDispatchState.rejected,
      'unknown' => FloorPlanDispatchState.unknown,
      _ => _invalid(),
    };
    final provider = command['providerAccepted'];
    final matches = command['observationMatchesTarget'];
    if (provider != null && provider is! bool ||
        matches != null && matches is! bool) {
      _invalid();
    }
    final created = _timestamp(command['createdAt']);
    final completed = command['completedAt'] == null
        ? null
        : _timestamp(command['completedAt']);
    final observed = command['observedProjection'];
    final observedState = observed == null
        ? null
        : _commandProjection(observed);
    final targetState = expectedRequest.action == FloorPlanAction.turnOn
        ? 'on'
        : 'off';
    if (completed != null && completed.isBefore(created) ||
        dispatch == FloorPlanDispatchState.pending &&
            (provider != null ||
                observed != null ||
                matches != null ||
                completed != null) ||
        dispatch == FloorPlanDispatchState.accepted && provider != true ||
        dispatch == FloorPlanDispatchState.rejected && provider != false ||
        dispatch == FloorPlanDispatchState.unknown && provider != null ||
        observed == null && matches != null ||
        observed != null && matches == null ||
        observed != null && matches != (observedState == targetState) ||
        dispatch != FloorPlanDispatchState.pending && completed == null) {
      _invalid();
    }
    return FloorPlanActionReceipt._(dispatch);
  }

  final FloorPlanDispatchState dispatchState;
}

String _commandProjection(Object? value) {
  final json = _object(value, const {'kind', 'state', 'commandAvailable'});
  final kind = json['kind'];
  if (kind is! String ||
      kind.isEmpty ||
      kind.length > 64 ||
      !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(kind) ||
      json['commandAvailable'] is! bool) {
    _invalid();
  }
  final state = _state(json['state']);
  if (kind != 'switch' || !{'on', 'off', 'unavailable'}.contains(state)) {
    _invalid();
  }
  return state;
}

DateTime _timestamp(Object? value) {
  if (value is! String ||
      value.length > 40 ||
      !RegExp(r'T.*(?:Z|\+00:00)$').hasMatch(value)) {
    _invalid();
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) _invalid();
  return parsed;
}
