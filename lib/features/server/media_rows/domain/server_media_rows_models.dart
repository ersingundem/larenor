Never _invalid() => throw const FormatException('invalid_response');

final _identityPattern = RegExp(r'^[0-9a-f]{32}$');
final _unsafeText = RegExp(r'\p{C}', unicode: true);

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _identity(Object? value) {
  if (value is! String || !_identityPattern.hasMatch(value)) _invalid();
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7ffffffffffffffe) _invalid();
  return value;
}

enum ServerMediaRowKind { movie, episode }

final class ServerMediaRowItem {
  const ServerMediaRowItem._({
    required this.itemId,
    required this.title,
    required this.kind,
    required this.addedAt,
    required this.runtimeSeconds,
    required this.positionSeconds,
  });

  factory ServerMediaRowItem.fromJson(Object? value) {
    final map = _object(value, {
      'itemId',
      'title',
      'mediaKind',
      'addedAt',
      'runtimeSeconds',
      'positionSeconds',
    });
    final title = map['title'];
    final addedAt = map['addedAt'];
    final runtime = map['runtimeSeconds'];
    final position = map['positionSeconds'];
    if (title is! String ||
        title.isEmpty ||
        title.length > 240 ||
        title != title.trim() ||
        _unsafeText.hasMatch(title) ||
        addedAt is! int ||
        addedAt < 1 ||
        addedAt > 253402300799 ||
        runtime is! int ||
        runtime < 1 ||
        runtime > 604800 ||
        position is! int ||
        position < 0 ||
        position >= runtime) {
      _invalid();
    }
    return ServerMediaRowItem._(
      itemId: _identity(map['itemId']),
      title: title,
      kind: switch (map['mediaKind']) {
        'movie' => ServerMediaRowKind.movie,
        'episode' => ServerMediaRowKind.episode,
        _ => _invalid(),
      },
      addedAt: DateTime.fromMillisecondsSinceEpoch(addedAt * 1000, isUtc: true),
      runtimeSeconds: runtime,
      positionSeconds: position,
    );
  }

  final String itemId, title;
  final ServerMediaRowKind kind;
  final DateTime addedAt;
  final int runtimeSeconds, positionSeconds;

  double get progress => positionSeconds / runtimeSeconds;
}

final class ServerMediaRows {
  const ServerMediaRows._({
    required this.revision,
    required this.recent,
    required this.resume,
  });

  factory ServerMediaRows.fromJson(Object? value) {
    final map = _object(value, {
      'schemaVersion',
      'revision',
      'recent',
      'resume',
    });
    final rawRecent = map['recent'];
    final rawResume = map['resume'];
    if (map['schemaVersion'] != 1 ||
        map['schemaVersion'] is! int ||
        rawRecent is! List ||
        rawRecent.length > 24 ||
        rawResume is! List ||
        rawResume.length > 24) {
      _invalid();
    }
    final recent = rawRecent
        .map(ServerMediaRowItem.fromJson)
        .toList(growable: false);
    final resume = rawResume
        .map(ServerMediaRowItem.fromJson)
        .toList(growable: false);
    if (recent.any((item) => item.positionSeconds != 0) ||
        resume.any((item) => item.positionSeconds == 0) ||
        recent.map((item) => item.itemId).toSet().length != recent.length ||
        resume.map((item) => item.itemId).toSet().length != resume.length) {
      _invalid();
    }
    return ServerMediaRows._(
      revision: _revision(map['revision']),
      recent: List.unmodifiable(recent),
      resume: List.unmodifiable(resume),
    );
  }

  final int revision;
  final List<ServerMediaRowItem> recent, resume;
}

final class ServerAccountMediaRows {
  const ServerAccountMediaRows._({
    required this.requestId,
    required this.installationId,
    required this.installationRevision,
    required this.bindingRevision,
    required this.rows,
  });

  factory ServerAccountMediaRows.fromJson(
    Object? value, {
    required String expectedRequestId,
    required String expectedInstallationId,
    required int expectedInstallationRevision,
  }) {
    final map = _object(value, {
      'requestId',
      'installationId',
      'installationRevision',
      'bindingRevision',
      'rows',
    });
    final requestId = _identity(map['requestId']);
    final installationId = _identity(map['installationId']);
    final installationRevision = _revision(map['installationRevision']);
    if (requestId != expectedRequestId ||
        installationId != expectedInstallationId ||
        installationRevision != expectedInstallationRevision) {
      _invalid();
    }
    return ServerAccountMediaRows._(
      requestId: requestId,
      installationId: installationId,
      installationRevision: installationRevision,
      bindingRevision: _revision(map['bindingRevision']),
      rows: ServerMediaRows.fromJson(map['rows']),
    );
  }

  final String requestId, installationId;
  final int installationRevision, bindingRevision;
  final ServerMediaRows rows;
}
