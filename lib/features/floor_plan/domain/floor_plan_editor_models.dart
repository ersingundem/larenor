import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

List<Object?> _list(Object? value, int max, {int min = 0}) {
  if (value is! List || value.length < min || value.length > max) _invalid();
  return value.cast<Object?>();
}

String _id(Object? value, {bool identity = false}) {
  if (value is! String ||
      (identity
          ? !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
          : value.isEmpty ||
                value.length > 128 ||
                !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value))) {
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

int _revision(Object? value, {bool zero = false}) {
  if (value is! int || value < (zero ? 0 : 1) || value > 9223372036854775807) {
    _invalid();
  }
  return value;
}

double _number(Object? value, {double min = 0, double max = 1}) {
  if (value is! num || !value.isFinite || value < min || value > max) {
    _invalid();
  }
  return value.toDouble();
}

@immutable
final class FloorPlanEditorPoint {
  const FloorPlanEditorPoint(this.x, this.y);

  factory FloorPlanEditorPoint.fromJson(Object? value) {
    final json = _object(value, const {'x', 'y'});
    return FloorPlanEditorPoint(_number(json['x']), _number(json['y']));
  }

  final double x, y;
  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

@immutable
final class FloorPlanEditorFloor {
  const FloorPlanEditorFloor({
    required this.id,
    required this.label,
    required this.order,
  });

  factory FloorPlanEditorFloor.fromJson(Object? value) {
    final json = _object(value, const {'floorId', 'label', 'order'});
    final order = json['order'];
    if (order is! int || order < 0 || order > 7) _invalid();
    return FloorPlanEditorFloor(
      id: _id(json['floorId']),
      label: _label(json['label']),
      order: order,
    );
  }

  final String id, label;
  final int order;
  Map<String, dynamic> toJson() => {
    'floorId': id,
    'label': label,
    'order': order,
  };
}

@immutable
final class FloorPlanEditorRoom {
  const FloorPlanEditorRoom({
    required this.id,
    required this.floorId,
    required this.label,
    required this.polygon,
  });

  factory FloorPlanEditorRoom.fromJson(Object? value) {
    final json = _object(value, const {
      'roomId',
      'floorId',
      'label',
      'polygon',
    });
    return FloorPlanEditorRoom(
      id: _id(json['roomId']),
      floorId: _id(json['floorId']),
      label: _label(json['label']),
      polygon: List.unmodifiable(
        _list(json['polygon'], 64, min: 3).map(FloorPlanEditorPoint.fromJson),
      ),
    );
  }

  final String id, floorId, label;
  final List<FloorPlanEditorPoint> polygon;
  Map<String, dynamic> toJson() => {
    'roomId': id,
    'floorId': floorId,
    'label': label,
    'polygon': polygon.map((item) => item.toJson()).toList(),
  };
}

@immutable
final class FloorPlanEditorAnchor {
  const FloorPlanEditorAnchor({
    required this.id,
    required this.roomId,
    required this.targetKind,
    required this.targetId,
    required this.targetRevision,
    required this.x,
    required this.y,
    required this.rotation,
  });

  factory FloorPlanEditorAnchor.fromJson(Object? value) {
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
    if (kind != 'entity' && kind != 'resource') _invalid();
    return FloorPlanEditorAnchor(
      id: _id(json['anchorId']),
      roomId: _id(json['roomId']),
      targetKind: kind! as String,
      targetId: _id(json['targetId']),
      targetRevision: _revision(json['targetRevision']),
      x: _number(json['x']),
      y: _number(json['y']),
      rotation: _number(json['rotation'], min: -360, max: 360),
    );
  }

  final String id, roomId, targetKind, targetId;
  final int targetRevision;
  final double x, y, rotation;

  FloorPlanEditorAnchor copyWith({
    String? roomId,
    String? targetKind,
    String? targetId,
    int? targetRevision,
    double? x,
    double? y,
  }) => FloorPlanEditorAnchor(
    id: id,
    roomId: roomId ?? this.roomId,
    targetKind: targetKind ?? this.targetKind,
    targetId: targetId ?? this.targetId,
    targetRevision: targetRevision ?? this.targetRevision,
    x: x ?? this.x,
    y: y ?? this.y,
    rotation: rotation,
  );

  Map<String, dynamic> toJson() => {
    'anchorId': id,
    'roomId': roomId,
    'targetKind': targetKind,
    'targetId': targetId,
    'targetRevision': targetRevision,
    'x': x,
    'y': y,
    'rotation': rotation,
  };
}

@immutable
final class FloorPlanEditorVector {
  const FloorPlanEditorVector({
    required this.id,
    required this.floorId,
    required this.kind,
    required this.points,
  });

  factory FloorPlanEditorVector.fromJson(Object? value) {
    final json = _object(value, const {'shapeId', 'floorId', 'kind', 'points'});
    final kind = json['kind'];
    if (!{'wall', 'door', 'window', 'path'}.contains(kind)) _invalid();
    return FloorPlanEditorVector(
      id: _id(json['shapeId']),
      floorId: _id(json['floorId']),
      kind: kind! as String,
      points: List.unmodifiable(
        _list(json['points'], 128, min: 2).map(FloorPlanEditorPoint.fromJson),
      ),
    );
  }

  final String id, floorId, kind;
  final List<FloorPlanEditorPoint> points;
  Map<String, dynamic> toJson() => {
    'shapeId': id,
    'floorId': floorId,
    'kind': kind,
    'points': points.map((item) => item.toJson()).toList(),
  };
}

@immutable
final class FloorPlanEditorLayout {
  const FloorPlanEditorLayout({
    required this.floors,
    required this.rooms,
    required this.anchors,
    required this.vectors,
  });

  factory FloorPlanEditorLayout.fromJson(Object? value) {
    final json = _object(value, const {
      'floors',
      'rooms',
      'anchors',
      'vectors',
    });
    final floors = _list(
      json['floors'],
      8,
      min: 1,
    ).map(FloorPlanEditorFloor.fromJson).toList();
    final rooms = _list(
      json['rooms'],
      128,
      min: 1,
    ).map(FloorPlanEditorRoom.fromJson).toList();
    final anchors = _list(
      json['anchors'],
      512,
    ).map(FloorPlanEditorAnchor.fromJson).toList();
    final vectors = _list(
      json['vectors'],
      512,
    ).map(FloorPlanEditorVector.fromJson).toList();
    final floorIds = floors.map((item) => item.id).toSet();
    final roomIds = rooms.map((item) => item.id).toSet();
    final targets = anchors
        .map((item) => '${item.targetKind}\u0000${item.targetId}')
        .toSet();
    final pointCount =
        rooms.fold<int>(0, (sum, item) => sum + item.polygon.length) +
        vectors.fold<int>(0, (sum, item) => sum + item.points.length);
    if (floorIds.length != floors.length ||
        floors.map((item) => item.order).toSet().length != floors.length ||
        roomIds.length != rooms.length ||
        rooms.any((item) => !floorIds.contains(item.floorId)) ||
        anchors.map((item) => item.id).toSet().length != anchors.length ||
        targets.length != anchors.length ||
        anchors.any((item) => !roomIds.contains(item.roomId)) ||
        vectors.map((item) => item.id).toSet().length != vectors.length ||
        vectors.any((item) => !floorIds.contains(item.floorId)) ||
        pointCount > 4096) {
      _invalid();
    }
    return FloorPlanEditorLayout(
      floors: List.unmodifiable(floors),
      rooms: List.unmodifiable(rooms),
      anchors: List.unmodifiable(anchors),
      vectors: List.unmodifiable(vectors),
    );
  }

  final List<FloorPlanEditorFloor> floors;
  final List<FloorPlanEditorRoom> rooms;
  final List<FloorPlanEditorAnchor> anchors;
  final List<FloorPlanEditorVector> vectors;

  Map<String, dynamic> toJson() => {
    'floors': floors.map((item) => item.toJson()).toList(),
    'rooms': rooms.map((item) => item.toJson()).toList(),
    'anchors': anchors.map((item) => item.toJson()).toList(),
    'vectors': vectors.map((item) => item.toJson()).toList(),
  };
}

@immutable
final class FloorPlanEditorRoomCandidate {
  const FloorPlanEditorRoomCandidate(this.id, this.label, this.revision);
  factory FloorPlanEditorRoomCandidate.fromJson(Object? value) {
    final json = _object(value, const {'roomId', 'label', 'revision'});
    return FloorPlanEditorRoomCandidate(
      _id(json['roomId'], identity: true),
      _label(json['label']),
      _revision(json['revision']),
    );
  }
  final String id, label;
  final int revision;
}

@immutable
final class FloorPlanEditorTargetCandidate {
  const FloorPlanEditorTargetCandidate({
    required this.kind,
    required this.id,
    required this.revision,
    required this.label,
  });
  factory FloorPlanEditorTargetCandidate.fromJson(Object? value) {
    final json = _object(value, const {
      'targetKind',
      'targetId',
      'targetRevision',
      'label',
    });
    final kind = json['targetKind'];
    if (kind != 'entity' && kind != 'resource') _invalid();
    return FloorPlanEditorTargetCandidate(
      kind: kind! as String,
      id: _id(json['targetId']),
      revision: _revision(json['targetRevision']),
      label: _label(json['label']),
    );
  }
  final String kind, id, label;
  final int revision;
  String get key => '$kind\u0000$id';
}

@immutable
final class FloorPlanEditorCatalog {
  const FloorPlanEditorCatalog._({
    required this.context,
    required this.layoutRevision,
    required this.entityRegistryRevision,
    required this.resourceRevision,
    required this.grantRevision,
    required this.layout,
    required this.rooms,
    required this.targets,
  });

  factory FloorPlanEditorCatalog.fromResponse(
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
      'rooms',
      'targets',
    });
    if (json['schemaVersion'] != 1) _invalid();
    final layoutRevision = _revision(json['layoutRevision'], zero: true);
    final layout = json['layout'] == null
        ? null
        : FloorPlanEditorLayout.fromJson(json['layout']);
    if ((layout == null) != (layoutRevision == 0)) _invalid();
    final rooms = _list(
      json['rooms'],
      512,
    ).map(FloorPlanEditorRoomCandidate.fromJson).toList();
    final targets = _list(
      json['targets'],
      768,
    ).map(FloorPlanEditorTargetCandidate.fromJson).toList();
    if (rooms.map((item) => item.id).toSet().length != rooms.length ||
        targets.map((item) => item.key).toSet().length != targets.length) {
      _invalid();
    }
    return FloorPlanEditorCatalog._(
      context: expected,
      layoutRevision: layoutRevision,
      entityRegistryRevision: _revision(json['entityRegistryRevision']),
      resourceRevision: _revision(json['resourceRevision']),
      grantRevision: _revision(json['grantRevision']),
      layout: layout,
      rooms: List.unmodifiable(rooms),
      targets: List.unmodifiable(targets),
    );
  }

  final ServerContext context;
  final int layoutRevision,
      entityRegistryRevision,
      resourceRevision,
      grantRevision;
  final FloorPlanEditorLayout? layout;
  final List<FloorPlanEditorRoomCandidate> rooms;
  final List<FloorPlanEditorTargetCandidate> targets;
}

@immutable
final class FloorPlanEditorSaveRequest {
  const FloorPlanEditorSaveRequest._({
    required this.requestId,
    required this.catalog,
    required this.layout,
  });

  factory FloorPlanEditorSaveRequest.forCatalog({
    required String requestId,
    required FloorPlanEditorCatalog catalog,
    required FloorPlanEditorLayout layout,
  }) {
    _id(requestId, identity: true);
    return FloorPlanEditorSaveRequest._(
      requestId: requestId,
      catalog: catalog,
      layout: layout,
    );
  }

  final String requestId;
  final FloorPlanEditorCatalog catalog;
  final FloorPlanEditorLayout layout;
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'expectedLayoutRevision': catalog.layoutRevision,
    'expectedEntityRegistryRevision': catalog.entityRegistryRevision,
    'expectedResourceRevision': catalog.resourceRevision,
    'expectedGrantRevision': catalog.grantRevision,
    'layout': layout.toJson(),
  };
}

@immutable
final class FloorPlanEditorReceipt {
  const FloorPlanEditorReceipt._(this.requestId, this.revision);
  factory FloorPlanEditorReceipt.fromResponse(
    Object? value, {
    required String expectedRequestId,
  }) {
    final root = _object(value, const {'receipt'});
    final receipt = _object(root['receipt'], const {
      'requestId',
      'revision',
      'status',
    });
    if (receipt['requestId'] != expectedRequestId ||
        receipt['status'] != 'saved') {
      _invalid();
    }
    return FloorPlanEditorReceipt._(
      expectedRequestId,
      _revision(receipt['revision']),
    );
  }
  final String requestId;
  final int revision;
}
