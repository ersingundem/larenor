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

String _label(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 80 ||
      value.runes.any((rune) => rune < 32)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) _invalid();
  return value;
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

@immutable
final class FloorPlanSnapshot {
  const FloorPlanSnapshot._({
    required this.context,
    required this.revision,
    required this.floors,
    required this.rooms,
    required this.anchors,
    required this.vectors,
  });

  factory FloorPlanSnapshot.fromResponse(
    Object? value, {
    required ServerContext expected,
  }) {
    final json = _object(value, const {'layoutRevision', 'layout'});
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
    final floorIds = floors.map((item) => item.id).toSet();
    final roomIds = rooms.map((item) => item.id).toSet();
    if (floorIds.length != floors.length ||
        roomIds.length != rooms.length ||
        rooms.any((item) => !floorIds.contains(item.floorId)) ||
        anchors.map((item) => item.id).toSet().length != anchors.length ||
        anchors.any((item) => !roomIds.contains(item.roomId)) ||
        vectors.map((item) => item.id).toSet().length != vectors.length ||
        vectors.any((item) => !floorIds.contains(item.floorId))) {
      _invalid();
    }
    return FloorPlanSnapshot._(
      context: expected,
      revision: _revision(json['layoutRevision']),
      floors: List.unmodifiable(floors),
      rooms: List.unmodifiable(rooms),
      anchors: List.unmodifiable(anchors),
      vectors: List.unmodifiable(vectors),
    );
  }

  final ServerContext context;
  final int revision;
  final List<FloorPlanFloor> floors;
  final List<FloorPlanRoom> rooms;
  final List<FloorPlanAnchor> anchors;
  final List<FloorPlanVector> vectors;
}
