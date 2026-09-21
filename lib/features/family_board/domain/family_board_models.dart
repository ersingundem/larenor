import 'dart:convert';

final class FamilyBoardException implements Exception {
  const FamilyBoardException(this.code);
  final String code;
  @override
  String toString() => 'FamilyBoardException($code)';
}

Never _invalid() => throw const FamilyBoardException('invalid_response');

Map<Object?, Object?> _map(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _hash(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _positive(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) _invalid();
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 0 || value > 9223372036854775807) _invalid();
  return value;
}

double _number(Object? value, {double min = -100000, double max = 100000}) {
  if (value is! num || !value.isFinite || value < min || value > max) {
    _invalid();
  }
  return value.toDouble();
}

final class FamilyBoardBinding {
  factory FamilyBoardBinding({
    required String coreId,
    required String homeId,
    required int homeRevision,
    required String boardId,
    required String accountId,
    required int accountRevision,
    required int memberRevision,
    required String sessionFamilyId,
    required int routeRevision,
    required int lifecycleRevision,
    required bool active,
    required bool canWrite,
  }) => FamilyBoardBinding._(
    _id(coreId),
    _id(homeId),
    _positive(homeRevision),
    _id(boardId),
    _id(accountId),
    _positive(accountRevision),
    _positive(memberRevision),
    _id(sessionFamilyId),
    _positive(routeRevision),
    _positive(lifecycleRevision),
    active,
    canWrite,
  );

  factory FamilyBoardBinding.fromAuthority(
    Object? raw, {
    required String coreId,
    required String homeId,
    required String accountId,
    required int routeRevision,
    required int lifecycleRevision,
  }) {
    final value = _map(raw, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'homeRevision',
      'boardId',
      'accountId',
      'accountRevision',
      'memberRevision',
      'sessionFamilyId',
      'role',
      'canRead',
      'canWrite',
      'active',
    });
    if (value['schemaVersion'] != 1 ||
        value['canRead'] != true ||
        value['active'] != true ||
        value['canWrite'] is! bool ||
        value['role'] != 'admin' && value['role'] != 'member' ||
        _id(value['coreId']) != coreId ||
        _id(value['homeId']) != homeId ||
        _id(value['accountId']) != accountId) {
      _invalid();
    }
    return FamilyBoardBinding(
      coreId: coreId,
      homeId: homeId,
      homeRevision: _positive(value['homeRevision']),
      boardId: _id(value['boardId']),
      accountId: accountId,
      accountRevision: _positive(value['accountRevision']),
      memberRevision: _positive(value['memberRevision']),
      sessionFamilyId: _id(value['sessionFamilyId']),
      routeRevision: routeRevision,
      lifecycleRevision: lifecycleRevision,
      active: true,
      canWrite: value['canWrite'] as bool,
    );
  }

  const FamilyBoardBinding._(
    this.coreId,
    this.homeId,
    this.homeRevision,
    this.boardId,
    this.accountId,
    this.accountRevision,
    this.memberRevision,
    this.sessionFamilyId,
    this.routeRevision,
    this.lifecycleRevision,
    this.active,
    this.canWrite,
  );

  final String coreId, homeId, boardId, accountId, sessionFamilyId;
  final int homeRevision,
      accountRevision,
      memberRevision,
      routeRevision,
      lifecycleRevision;
  final bool active, canWrite;

  Map<String, Object> get serverAuthority => {
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
    'homeRevision': homeRevision,
    'boardId': boardId,
    'accountId': accountId,
    'accountRevision': accountRevision,
    'memberRevision': memberRevision,
    'sessionFamilyId': sessionFamilyId,
  };

  void validateServerAuthority(Object? raw) {
    final value = _map(raw, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'homeRevision',
      'boardId',
      'accountId',
      'accountRevision',
      'memberRevision',
      'sessionFamilyId',
      'role',
      'canRead',
      'canWrite',
      'active',
    });
    if (value['schemaVersion'] != 1 ||
        value['canRead'] != true ||
        value['active'] != true ||
        value['canWrite'] is! bool ||
        value['role'] != 'admin' && value['role'] != 'member' ||
        _id(value['coreId']) != coreId ||
        _id(value['homeId']) != homeId ||
        _positive(value['homeRevision']) != homeRevision ||
        _id(value['boardId']) != boardId ||
        _id(value['accountId']) != accountId ||
        _positive(value['accountRevision']) != accountRevision ||
        _positive(value['memberRevision']) != memberRevision ||
        _id(value['sessionFamilyId']) != sessionFamilyId ||
        value['canWrite'] != canWrite) {
      _invalid();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FamilyBoardBinding &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      homeRevision == other.homeRevision &&
      boardId == other.boardId &&
      accountId == other.accountId &&
      accountRevision == other.accountRevision &&
      memberRevision == other.memberRevision &&
      sessionFamilyId == other.sessionFamilyId &&
      routeRevision == other.routeRevision &&
      lifecycleRevision == other.lifecycleRevision &&
      active == other.active &&
      canWrite == other.canWrite;
  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    homeRevision,
    boardId,
    accountId,
    accountRevision,
    memberRevision,
    sessionFamilyId,
    routeRevision,
    lifecycleRevision,
    active,
    canWrite,
  );
  @override
  String toString() => 'FamilyBoardBinding';
}

enum BoardElementKind { card, stroke }

enum BoardAction { append, update, delete }

final class BoardPoint {
  const BoardPoint(this.x, this.y);
  factory BoardPoint.fromJson(Object? raw) {
    final value = _map(raw, const {'x', 'y'});
    return BoardPoint(_number(value['x']), _number(value['y']));
  }
  final double x, y;
  Map<String, double> toJson() => {'x': x, 'y': y};
}

sealed class BoardElement {
  const BoardElement(this.id, this.kind);
  factory BoardElement.fromJson(Object? raw) {
    if (raw is! Map) _invalid();
    return switch (raw['kind']) {
      'card' => BoardCard.fromJson(raw),
      'stroke' => BoardStroke.fromJson(raw),
      _ => _invalid(),
    };
  }
  final String id;
  final BoardElementKind kind;
  Map<String, Object?> toJson();
}

final class BoardCard extends BoardElement {
  factory BoardCard({
    required String id,
    required String text,
    required double x,
    required double y,
    required String color,
  }) {
    final clean = text.trim();
    if (clean.isEmpty ||
        text.runes.length > 2000 ||
        text.runes.any((r) => r == 0 || r >= 0xd800 && r <= 0xdfff) ||
        !const {'yellow', 'blue', 'green', 'pink', 'gray'}.contains(color)) {
      _invalid();
    }
    return BoardCard._(_id(id), text, _number(x), _number(y), color);
  }
  factory BoardCard.fromJson(Object? raw) {
    final value = _map(raw, const {
      'schemaVersion',
      'id',
      'kind',
      'text',
      'x',
      'y',
      'color',
    });
    if (value['schemaVersion'] != 1 ||
        value['kind'] != 'card' ||
        value['text'] is! String ||
        value['color'] is! String) {
      _invalid();
    }
    return BoardCard(
      id: _id(value['id']),
      text: value['text'] as String,
      x: _number(value['x']),
      y: _number(value['y']),
      color: value['color'] as String,
    );
  }
  const BoardCard._(String id, this.text, this.x, this.y, this.color)
    : super(id, BoardElementKind.card);
  final String text, color;
  final double x, y;
  @override
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'kind': 'card',
    'text': text,
    'x': x,
    'y': y,
    'color': color,
  };
}

final class BoardStroke extends BoardElement {
  factory BoardStroke({
    required String id,
    required String color,
    required double width,
    required List<BoardPoint> points,
  }) {
    if (!const {'black', 'blue', 'green', 'red', 'white'}.contains(color) ||
        !width.isFinite ||
        width <= 0 ||
        width > 64 ||
        points.length < 2 ||
        points.length > 256) {
      _invalid();
    }
    return BoardStroke._(_id(id), color, width, List.unmodifiable(points));
  }
  factory BoardStroke.fromJson(Object? raw) {
    final value = _map(raw, const {
      'schemaVersion',
      'id',
      'kind',
      'color',
      'width',
      'points',
    });
    final source = value['points'];
    if (value['schemaVersion'] != 1 ||
        value['kind'] != 'stroke' ||
        value['color'] is! String ||
        source is! List) {
      _invalid();
    }
    return BoardStroke(
      id: _id(value['id']),
      color: value['color'] as String,
      width: _number(value['width'], min: 0.000001, max: 64),
      points: source.map(BoardPoint.fromJson).toList(growable: false),
    );
  }
  const BoardStroke._(String id, this.color, this.width, this.points)
    : super(id, BoardElementKind.stroke);
  final String color;
  final double width;
  final List<BoardPoint> points;
  @override
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'kind': 'stroke',
    'color': color,
    'width': width,
    'points': points.map((p) => p.toJson()).toList(growable: false),
  };
}

final class FamilyBoardSnapshot {
  const FamilyBoardSnapshot._(
    this.binding,
    this.boardRevision,
    this.auditHead,
    this.elements,
  );
  factory FamilyBoardSnapshot.fromJson(
    Object? raw,
    FamilyBoardBinding expected,
  ) {
    final value = _map(raw, const {
      'schemaVersion',
      'authority',
      'boardRevision',
      'auditHead',
      'elements',
    });
    if (value['schemaVersion'] != 1) _invalid();
    expected.validateServerAuthority(value['authority']);
    final source = value['elements'];
    if (source is! List || source.length > 512) _invalid();
    final elements = source.map(BoardElement.fromJson).toList(growable: false);
    if (elements.map((e) => e.id).toSet().length != elements.length) _invalid();
    return FamilyBoardSnapshot._(
      expected,
      _positive(value['boardRevision']),
      _hash(value['auditHead']),
      List.unmodifiable(elements),
    );
  }
  final FamilyBoardBinding binding;
  final int boardRevision;
  final String auditHead;
  final List<BoardElement> elements;
  List<BoardCard> get cards =>
      elements.whereType<BoardCard>().toList(growable: false);
  List<BoardStroke> get strokes =>
      elements.whereType<BoardStroke>().toList(growable: false);
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'authority': {
      ...binding.serverAuthority,
      'role': binding.canWrite ? 'admin' : 'member',
      'canRead': true,
      'canWrite': binding.canWrite,
      'active': true,
    },
    'boardRevision': boardRevision,
    'auditHead': auditHead,
    'elements': elements.map((e) => e.toJson()).toList(growable: false),
  };
}

final class FamilyBoardAuditEvent {
  const FamilyBoardAuditEvent._(
    this.sequence,
    this.action,
    this.actorId,
    this.elementId,
    this.boardRevision,
    this.createdAt,
    this.previousHash,
    this.eventHash,
  );
  factory FamilyBoardAuditEvent.fromJson(Object? raw) {
    final value = _map(raw, const {
      'schemaVersion',
      'sequence',
      'action',
      'actorId',
      'elementId',
      'boardRevision',
      'createdAt',
      'previousHash',
      'eventHash',
    });
    final action = switch (value['action']) {
      'append' => BoardAction.append,
      'update' => BoardAction.update,
      'delete' => BoardAction.delete,
      _ => _invalid(),
    };
    final created = _number(value['createdAt'], min: 0, max: 9007199254740991);
    return FamilyBoardAuditEvent._(
      _positive(value['sequence']),
      action,
      _id(value['actorId']),
      _id(value['elementId']),
      _positive(value['boardRevision']),
      created,
      _hash(value['previousHash']),
      _hash(value['eventHash']),
    );
  }
  final int sequence, boardRevision;
  final BoardAction action;
  final String actorId, elementId, previousHash, eventHash;
  final double createdAt;
}

final class FamilyBoardDelta {
  const FamilyBoardDelta._(
    this.boardRevision,
    this.afterSequence,
    this.nextAfter,
    this.auditHead,
    this.events,
  );
  factory FamilyBoardDelta.fromJson(
    Object? raw,
    FamilyBoardBinding expected, {
    required int expectedAfter,
  }) {
    final value = _map(raw, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'boardId',
      'boardRevision',
      'afterSequence',
      'nextAfter',
      'auditHead',
      'events',
    });
    final source = value['events'];
    if (value['schemaVersion'] != 1 ||
        _id(value['coreId']) != expected.coreId ||
        _id(value['homeId']) != expected.homeId ||
        _id(value['boardId']) != expected.boardId ||
        source is! List ||
        source.length > 100 ||
        _revision(value['afterSequence']) != expectedAfter) {
      _invalid();
    }
    final events = source
        .map(FamilyBoardAuditEvent.fromJson)
        .toList(growable: false);
    var previous = expectedAfter;
    for (final event in events) {
      if (event.sequence != previous + 1 ||
          event.boardRevision != event.sequence ||
          previous > expectedAfter &&
              event.previousHash !=
                  events[previous - expectedAfter - 1].eventHash) {
        _invalid();
      }
      previous = event.sequence;
    }
    final next = _revision(value['nextAfter']);
    final revision = _revision(value['boardRevision']);
    final head = _hash(value['auditHead']);
    if (next != previous ||
        next > revision ||
        events.isEmpty && revision != expectedAfter ||
        events.isNotEmpty &&
            next == revision &&
            events.last.eventHash != head) {
      _invalid();
    }
    return FamilyBoardDelta._(
      revision,
      expectedAfter,
      next,
      head,
      List.unmodifiable(events),
    );
  }
  final int boardRevision, afterSequence, nextAfter;
  final String auditHead;
  final List<FamilyBoardAuditEvent> events;
}

final class FamilyBoardCommand {
  const FamilyBoardCommand._(
    this.requestId,
    this.expectedBoardRevision,
    this.action,
    this.element,
    this.elementId,
  );
  factory FamilyBoardCommand.append(
    String requestId,
    int revision,
    BoardElement element,
  ) => FamilyBoardCommand._(
    _id(requestId),
    _revision(revision),
    BoardAction.append,
    element,
    null,
  );
  factory FamilyBoardCommand.update(
    String requestId,
    int revision,
    BoardElement element,
  ) => FamilyBoardCommand._(
    _id(requestId),
    _positive(revision),
    BoardAction.update,
    element,
    null,
  );
  factory FamilyBoardCommand.delete(
    String requestId,
    int revision,
    String elementId,
  ) => FamilyBoardCommand._(
    _id(requestId),
    _positive(revision),
    BoardAction.delete,
    null,
    _id(elementId),
  );
  final String requestId;
  final int expectedBoardRevision;
  final BoardAction action;
  final BoardElement? element;
  final String? elementId;
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'requestId': requestId,
    'expectedBoardRevision': expectedBoardRevision,
    'action': action.name,
    'element': element?.toJson(),
    'elementId': elementId,
  };
  @override
  String toString() => 'FamilyBoardCommand';
}

final class FamilyBoardReceipt {
  const FamilyBoardReceipt._(
    this.requestId,
    this.boardId,
    this.boardRevision,
    this.auditSequence,
    this.action,
    this.elementId,
  );
  factory FamilyBoardReceipt.fromJson(
    Object? raw,
    FamilyBoardCommand expected,
  ) {
    final value = _map(raw, const {
      'schemaVersion',
      'requestId',
      'boardId',
      'boardRevision',
      'auditSequence',
      'action',
      'elementId',
    });
    final action = switch (value['action']) {
      'append' => BoardAction.append,
      'update' => BoardAction.update,
      'delete' => BoardAction.delete,
      _ => _invalid(),
    };
    final target = expected.element?.id ?? expected.elementId;
    final revision = _positive(value['boardRevision']);
    if (value['schemaVersion'] != 1 ||
        _id(value['requestId']) != expected.requestId ||
        action != expected.action ||
        _id(value['elementId']) != target ||
        revision != expected.expectedBoardRevision + 1 ||
        _positive(value['auditSequence']) != revision) {
      _invalid();
    }
    return FamilyBoardReceipt._(
      expected.requestId,
      _id(value['boardId']),
      revision,
      revision,
      action,
      target!,
    );
  }
  final String requestId, boardId, elementId;
  final int boardRevision, auditSequence;
  final BoardAction action;
}

String encodeBoardSnapshot(FamilyBoardSnapshot value) =>
    jsonEncode(value.toJson());
