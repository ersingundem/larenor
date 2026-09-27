Never _invalid() => throw const FormatException('invalid_response');

final _identityPattern = RegExp(r'^[0-9a-f]{32}$');
final _targetPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$');
final _unsafeText = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]',
);

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

final _qualityTokenPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.+,\-]{0,63}$');

String? _qualityToken(Object? value) {
  if (value == null) return null;
  if (value is! String || !_qualityTokenPattern.hasMatch(value)) _invalid();
  return value;
}

int? _qualityBitrate(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 1 || value > 1000000000) _invalid();
  return value;
}

List<String> _qualityTokens(Object? value, {required int maximum}) {
  if (value is! List || value.length > maximum) _invalid();
  final result = <String>[];
  for (final raw in value) {
    final token = _qualityToken(raw);
    if (token == null) _invalid();
    result.add(token);
  }
  if (result.toSet().length != result.length) _invalid();
  return List.unmodifiable(result);
}

enum ServerMediaPlaybackMethod { unknown, directPlay, directStream, transcode }

final class ServerMediaPlaybackSourceEvidence {
  const ServerMediaPlaybackSourceEvidence._({
    required this.container,
    required this.bitrate,
    required this.videoCodecs,
    required this.audioCodecs,
    required this.videoRanges,
  });

  factory ServerMediaPlaybackSourceEvidence.fromJson(Object? value) {
    final map = _object(value, {
      'container',
      'bitrate',
      'videoCodecs',
      'audioCodecs',
      'videoRanges',
    });
    return ServerMediaPlaybackSourceEvidence._(
      container: _qualityToken(map['container']),
      bitrate: _qualityBitrate(map['bitrate']),
      videoCodecs: _qualityTokens(map['videoCodecs'], maximum: 8),
      audioCodecs: _qualityTokens(map['audioCodecs'], maximum: 8),
      videoRanges: _qualityTokens(map['videoRanges'], maximum: 8),
    );
  }

  final String? container;
  final int? bitrate;
  final List<String> videoCodecs, audioCodecs, videoRanges;
}

final class ServerMediaPlaybackTranscodingEvidence {
  const ServerMediaPlaybackTranscodingEvidence._({
    required this.container,
    required this.videoCodec,
    required this.audioCodec,
    required this.bitrate,
    required this.reasons,
  });

  factory ServerMediaPlaybackTranscodingEvidence.fromJson(Object? value) {
    final map = _object(value, {
      'container',
      'videoCodec',
      'audioCodec',
      'bitrate',
      'reasons',
    });
    return ServerMediaPlaybackTranscodingEvidence._(
      container: _qualityToken(map['container']),
      videoCodec: _qualityToken(map['videoCodec']),
      audioCodec: _qualityToken(map['audioCodec']),
      bitrate: _qualityBitrate(map['bitrate']),
      reasons: _qualityTokens(map['reasons'], maximum: 16),
    );
  }

  final String? container, videoCodec, audioCodec;
  final int? bitrate;
  final List<String> reasons;
}

final class ServerMediaPlaybackQualityObservation {
  const ServerMediaPlaybackQualityObservation._({
    required this.itemId,
    required this.method,
    required this.source,
    required this.transcoding,
  });

  factory ServerMediaPlaybackQualityObservation.fromJson(Object? value) {
    final map = _object(value, {
      'schemaVersion',
      'itemId',
      'playMethod',
      'source',
      'transcoding',
    });
    if (map['schemaVersion'] != 1) _invalid();
    final method = switch (map['playMethod']) {
      'unknown' => ServerMediaPlaybackMethod.unknown,
      'direct_play' => ServerMediaPlaybackMethod.directPlay,
      'direct_stream' => ServerMediaPlaybackMethod.directStream,
      'transcode' => ServerMediaPlaybackMethod.transcode,
      _ => _invalid(),
    };
    final rawTranscoding = map['transcoding'];
    return ServerMediaPlaybackQualityObservation._(
      itemId: _identity(map['itemId']),
      method: method,
      source: ServerMediaPlaybackSourceEvidence.fromJson(map['source']),
      transcoding: rawTranscoding == null
          ? null
          : ServerMediaPlaybackTranscodingEvidence.fromJson(rawTranscoding),
    );
  }

  final String itemId;
  final ServerMediaPlaybackMethod method;
  final ServerMediaPlaybackSourceEvidence source;
  final ServerMediaPlaybackTranscodingEvidence? transcoding;
}

final class ServerMediaPlaybackTarget {
  const ServerMediaPlaybackTarget._({
    required this.id,
    required this.revision,
    required this.name,
    required this.available,
    required this.currentItemId,
    required this.positionSeconds,
    required this.qualityObservation,
  });

  factory ServerMediaPlaybackTarget.fromJson(Object? value) {
    final map = _object(value, {
      'targetId',
      'targetRevision',
      'name',
      'available',
      'currentItemId',
      'positionSeconds',
      'qualityObservation',
    });
    final available = map['available'];
    final current = map['currentItemId'];
    final position = map['positionSeconds'];
    final rawQuality = map['qualityObservation'];
    if (available is! bool ||
        current != null &&
            (current is! String || !_identityPattern.hasMatch(current)) ||
        position is! int ||
        position < 0 ||
        position > 8640000) {
      _invalid();
    }
    final quality = rawQuality == null
        ? null
        : ServerMediaPlaybackQualityObservation.fromJson(rawQuality);
    if (quality != null && quality.itemId != current) _invalid();
    return ServerMediaPlaybackTarget._(
      id: _target(map['targetId']),
      revision: _revision(map['targetRevision']),
      name: _text(map['name']),
      available: available,
      currentItemId: current as String?,
      positionSeconds: position,
      qualityObservation: quality,
    );
  }

  final String id, name;
  final int revision, positionSeconds;
  final bool available;
  final String? currentItemId;
  final ServerMediaPlaybackQualityObservation? qualityObservation;
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
