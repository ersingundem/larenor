Never _invalid() => throw const FormatException('invalid_response');

final _identityPattern = RegExp(r'^[0-9a-f]{32}$');
final _targetPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$');
final _unsafeText = RegExp(r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]');

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

String _target(Object? value) {
  if (value is! String || !_targetPattern.hasMatch(value)) _invalid();
  return value;
}

String _text(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 128 ||
      value != value.trim() ||
      _unsafeText.hasMatch(value)) {
    _invalid();
  }
  return value;
}

final class ServerMediaPlaybackTarget {
  const ServerMediaPlaybackTarget._({
    required this.id,
    required this.revision,
    required this.name,
    required this.available,
    required this.currentItemId,
    required this.positionSeconds,
  });

  factory ServerMediaPlaybackTarget.fromJson(Object? value) {
    final map = _object(value, {
      'targetId',
      'targetRevision',
      'name',
      'available',
      'currentItemId',
      'positionSeconds',
    });
    final available = map['available'];
    final current = map['currentItemId'];
    final position = map['positionSeconds'];
    if (available is! bool ||
        current != null &&
            (current is! String || !_identityPattern.hasMatch(current)) ||
        position is! int ||
        position < 0 ||
        position > 8640000) {
      _invalid();
    }
    return ServerMediaPlaybackTarget._(
      id: _target(map['targetId']),
      revision: _revision(map['targetRevision']),
      name: _text(map['name']),
      available: available,
      currentItemId: current as String?,
      positionSeconds: position,
    );
  }

  final String id, name;
  final int revision, positionSeconds;
  final bool available;
  final String? currentItemId;
}

final class ServerMediaPlaybackIntent {
  const ServerMediaPlaybackIntent._({
    required this.id,
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
    required this.itemId,
    required this.mediaKey,
    required this.playbackRevision,
    required this.expiresAt,
    required this.targets,
  });

  factory ServerMediaPlaybackIntent.fromJson(Object? value) {
    final map = _object(value, {
      'requestId',
      'installationId',
      'expectedInstallationRevision',
      'expectedSnapshotRevision',
      'expectedJellyfinServiceRevision',
      'itemId',
      'mediaKey',
      'playbackRevision',
      'expiresAt',
      'targets',
    });
    final mediaKey = map['mediaKey'];
    final expiresAt = map['expiresAt'];
    final rawTargets = map['targets'];
    if (mediaKey is! String ||
        mediaKey.length > 96 ||
        !RegExp(
          r'^(?:movie:tmdb:[1-9][0-9]{0,11}|episode:tvdb:[1-9][0-9]{0,11}:[0-9]{1,4}:[0-9]{1,5})$',
        ).hasMatch(mediaKey) ||
        expiresAt is! int ||
        expiresAt < 1 ||
        expiresAt > 253402300799 ||
        rawTargets is! List ||
        rawTargets.isEmpty ||
        rawTargets.length > 64) {
      _invalid();
    }
    final targets = rawTargets
        .map(ServerMediaPlaybackTarget.fromJson)
        .toList(growable: false);
    if (targets.map((item) => item.id).toSet().length != targets.length) {
      _invalid();
    }
    return ServerMediaPlaybackIntent._(
      id: _identity(map['requestId']),
      installationId: _identity(map['installationId']),
      installationRevision: _revision(map['expectedInstallationRevision']),
      snapshotRevision: _revision(map['expectedSnapshotRevision']),
      jellyfinServiceRevision: _revision(
        map['expectedJellyfinServiceRevision'],
      ),
      itemId: _identity(map['itemId']),
      mediaKey: mediaKey,
      playbackRevision: _revision(map['playbackRevision']),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiresAt * 1000,
        isUtc: true,
      ),
      targets: List.unmodifiable(targets),
    );
  }

  final String id, installationId, itemId, mediaKey;
  final int installationRevision;
  final int snapshotRevision, jellyfinServiceRevision, playbackRevision;
  final DateTime expiresAt;
  final List<ServerMediaPlaybackTarget> targets;
}

enum ServerMediaPlaybackReceiptState { succeeded, needsAttention }

final class ServerMediaPlaybackReceipt {
  const ServerMediaPlaybackReceipt._({
    required this.requestId,
    required this.intentId,
    required this.installationId,
    required this.itemId,
    required this.targetId,
    required this.playbackRevision,
    required this.state,
    required this.effectUnknown,
  });

  factory ServerMediaPlaybackReceipt.fromJson(
    Object? value, {
    required String expectedRequestId,
    required String expectedIntentId,
    required String expectedInstallationId,
    required String expectedItemId,
    required String expectedTargetId,
    required int expectedPlaybackRevision,
  }) {
    final map = _object(value, {
      'requestId',
      'intentId',
      'installationId',
      'itemId',
      'targetId',
      'playbackRevision',
      'state',
      'code',
      'installAvailable',
    });
    final state = switch (map['state']) {
      'succeeded' => ServerMediaPlaybackReceiptState.succeeded,
      'needs_attention' => ServerMediaPlaybackReceiptState.needsAttention,
      _ => _invalid(),
    };
    final revision = _revision(map['playbackRevision']);
    final effectUnknown = map['code'] == 'effect_unknown';
    if (_identity(map['requestId']) != expectedRequestId ||
        _identity(map['intentId']) != expectedIntentId ||
        _identity(map['installationId']) != expectedInstallationId ||
        _identity(map['itemId']) != expectedItemId ||
        _target(map['targetId']) != expectedTargetId ||
        revision < expectedPlaybackRevision ||
        map['installAvailable'] != false ||
        (state == ServerMediaPlaybackReceiptState.succeeded &&
            (map['code'] != 'authenticated_readback' ||
                revision <= expectedPlaybackRevision)) ||
        (state == ServerMediaPlaybackReceiptState.needsAttention &&
            !effectUnknown)) {
      _invalid();
    }
    return ServerMediaPlaybackReceipt._(
      requestId: expectedRequestId,
      intentId: expectedIntentId,
      installationId: expectedInstallationId,
      itemId: expectedItemId,
      targetId: expectedTargetId,
      playbackRevision: revision,
      state: state,
      effectUnknown: effectUnknown,
    );
  }

  final String requestId, intentId, installationId, itemId, targetId;
  final int playbackRevision;
  final ServerMediaPlaybackReceiptState state;
  final bool effectUnknown;
}
