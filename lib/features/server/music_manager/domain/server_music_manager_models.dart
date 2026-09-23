import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _choice(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) _invalid();
  return value;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _binding(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _text(Object? value, {required int max}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) _invalid();
  return value;
}

double? _number(Object? value, {required double max, bool nullable = true}) {
  if (value == null && nullable) return null;
  if (value is! num || !value.isFinite || value < 0 || value > max) {
    _invalid();
  }
  return value.toDouble();
}

List<String> _strings(
  Object? value, {
  required int max,
  bool bindings = false,
}) {
  if (value is! List || value.length > max) _invalid();
  final result = value
      .map((item) => bindings ? _binding(item) : _text(item, max: 256))
      .toList(growable: false);
  if (result.toSet().length != result.length && bindings) _invalid();
  return List.unmodifiable(result);
}

enum ServerMusicOperation {
  play,
  pause,
  seek,
  queueAdd,
  queueReplace,
  queueClear,
}

extension ServerMusicOperationWire on ServerMusicOperation {
  String get wire => switch (this) {
    ServerMusicOperation.play => 'play',
    ServerMusicOperation.pause => 'pause',
    ServerMusicOperation.seek => 'seek',
    ServerMusicOperation.queueAdd => 'queue_add',
    ServerMusicOperation.queueReplace => 'queue_replace',
    ServerMusicOperation.queueClear => 'queue_clear',
  };
}

class ServerMusicProviderBinding {
  const ServerMusicProviderBinding._({
    required this.setupId,
    required this.revision,
    required this.domain,
    required this.instanceId,
  });

  factory ServerMusicProviderBinding.fromJson(Object? value) {
    final map = _object(value, {
      'setupId',
      'revision',
      'providerDomain',
      'providerInstanceId',
      'catalogAvailable',
    });
    if (map['catalogAvailable'] != true) _invalid();
    return ServerMusicProviderBinding._(
      setupId: _id(map['setupId']),
      revision: _revision(map['revision']),
      domain: _choice(map['providerDomain'], {
        'spotify',
        'apple_music',
        'ytmusic',
      }),
      instanceId: _binding(map['providerInstanceId']),
    );
  }

  final String setupId, domain, instanceId;
  final int revision;

  Map<String, Object> toJson() => {
    'setupId': setupId,
    'revision': revision,
    'providerDomain': domain,
    'providerInstanceId': instanceId,
    'catalogAvailable': true,
  };
}

class ServerMusicReceiver {
  const ServerMusicReceiver._({
    required this.id,
    required this.name,
    required this.provider,
    required this.kind,
    required this.available,
    required this.enabled,
    required this.playbackState,
    required this.volumeLevel,
    required this.muted,
    required this.groupMembers,
    required this.queueId,
    required this.positionSeconds,
    required this.capabilities,
  });

  factory ServerMusicReceiver.fromJson(Object? value) {
    final map = _object(value, {
      'playerId',
      'name',
      'provider',
      'targetKind',
      'available',
      'enabled',
      'playbackState',
      'volumeLevel',
      'muted',
      'groupMembers',
      'queueId',
      'positionSeconds',
      'capabilities',
    });
    if (map['available'] is! bool ||
        map['enabled'] is! bool ||
        (map['muted'] != null && map['muted'] is! bool) ||
        (map['volumeLevel'] != null &&
            (map['volumeLevel'] is! int ||
                (map['volumeLevel'] as int) < 0 ||
                (map['volumeLevel'] as int) > 100))) {
      _invalid();
    }
    final kind = _choice(map['targetKind'], {
      'homepod',
      'airplay',
      'airplay_group',
      'cast',
      'cast_group',
      'group',
      'other',
    });
    final members = _strings(map['groupMembers'], max: 64, bindings: true);
    if ({'airplay_group', 'group'}.contains(kind) != members.isNotEmpty) {
      _invalid();
    }
    final capabilities = _strings(map['capabilities'], max: 8, bindings: true);
    const allowed = {
      'play',
      'pause',
      'seek',
      'stop',
      'next_previous',
      'volume_set',
      'volume_mute',
      'queue',
    };
    if (!capabilities.every(allowed.contains) ||
        capabilities.toSet().length != capabilities.length) {
      _invalid();
    }
    return ServerMusicReceiver._(
      id: _binding(map['playerId']),
      name: _text(map['name'], max: 160),
      provider: _binding(map['provider']),
      kind: kind,
      available: map['available'] as bool,
      enabled: map['enabled'] as bool,
      playbackState: _choice(map['playbackState'], {
        'idle',
        'playing',
        'paused',
      }),
      volumeLevel: map['volumeLevel'] as int?,
      muted: map['muted'] as bool?,
      groupMembers: members,
      queueId: map['queueId'] == null ? null : _binding(map['queueId']),
      positionSeconds: _number(map['positionSeconds'], max: 864000),
      capabilities: capabilities,
    );
  }

  final String id, name, provider, kind, playbackState;
  final bool available, enabled;
  final int? volumeLevel;
  final bool? muted;
  final List<String> groupMembers, capabilities;
  final String? queueId;
  final double? positionSeconds;

  Map<String, Object?> toJson() => {
    'playerId': id,
    'name': name,
    'provider': provider,
    'targetKind': kind,
    'available': available,
    'enabled': enabled,
    'playbackState': playbackState,
    'volumeLevel': volumeLevel,
    'muted': muted,
    'groupMembers': groupMembers,
    'queueId': queueId,
    'positionSeconds': positionSeconds,
    'capabilities': capabilities,
  };

  bool supports(ServerMusicOperation operation) =>
      capabilities.contains(switch (operation) {
        ServerMusicOperation.play => 'play',
        ServerMusicOperation.pause => 'pause',
        ServerMusicOperation.seek => 'seek',
        ServerMusicOperation.queueAdd ||
        ServerMusicOperation.queueReplace ||
        ServerMusicOperation.queueClear => 'queue',
      });
}

class ServerMusicQueue {
  const ServerMusicQueue._({
    required this.id,
    required this.active,
    required this.itemCount,
    required this.currentItemUri,
    required this.positionSeconds,
  });

  factory ServerMusicQueue.fromJson(Object? value) {
    final map = _object(value, {
      'queueId',
      'active',
      'itemCount',
      'currentItemUri',
      'positionSeconds',
    });
    final count = map['itemCount'];
    final uri = map['currentItemUri'];
    if (map['active'] is! bool ||
        count is! int ||
        count < 0 ||
        count > 100000 ||
        (uri != null && !_validUri(uri))) {
      _invalid();
    }
    return ServerMusicQueue._(
      id: _binding(map['queueId']),
      active: map['active'] as bool,
      itemCount: count,
      currentItemUri: uri as String?,
      positionSeconds: _number(
        map['positionSeconds'],
        max: 864000,
        nullable: false,
      )!,
    );
  }

  final String id;
  final bool active;
  final int itemCount;
  final String? currentItemUri;
  final double positionSeconds;

  Map<String, Object?> toJson() => {
    'queueId': id,
    'active': active,
    'itemCount': itemCount,
    'currentItemUri': currentItemUri,
    'positionSeconds': positionSeconds,
  };
}

bool _validUri(Object? value) =>
    value is String &&
    value.length <= 2048 &&
    RegExp(r'^(?:spotify|apple_music|ytmusic|library)://[^\s]+$')
        .hasMatch(value);

class ServerMusicManager {
  const ServerMusicManager._({
    required this.installationId,
    required this.installationRevision,
    required this.coreRevision,
    required this.revision,
    required this.providers,
    required this.queues,
    required this.receivers,
    required this.updatedAt,
  });

  factory ServerMusicManager.fromJson(Object? value) {
    final map = _object(value, {
      'installationId',
      'installationRevision',
      'coreRevision',
      'revision',
      'providers',
      'queues',
      'receivers',
      'installAvailable',
      'updatedAt',
    });
    if (map['installAvailable'] != false ||
        map['providers'] is! List ||
        map['queues'] is! List ||
        map['receivers'] is! List ||
        (map['providers'] as List).length > 256 ||
        (map['queues'] as List).length > 256 ||
        (map['receivers'] as List).length > 256) {
      _invalid();
    }
    final updatedAt = map['updatedAt'] is String
        ? DateTime.tryParse(map['updatedAt'] as String)
        : null;
    if (updatedAt == null || updatedAt.toIso8601String() != map['updatedAt']) {
      _invalid();
    }
    final providers = (map['providers'] as List)
        .map(ServerMusicProviderBinding.fromJson)
        .toList(growable: false);
    final queues = (map['queues'] as List)
        .map(ServerMusicQueue.fromJson)
        .toList(growable: false);
    final receivers = (map['receivers'] as List)
        .map(ServerMusicReceiver.fromJson)
        .toList(growable: false);
    if (providers.map((item) => item.setupId).toSet().length !=
            providers.length ||
        queues.map((item) => item.id).toSet().length != queues.length ||
        receivers.map((item) => item.id).toSet().length != receivers.length) {
      _invalid();
    }
    final known = receivers.map((item) => item.id).toSet();
    if (receivers.any((item) => !known.containsAll(item.groupMembers))) {
      _invalid();
    }
    return ServerMusicManager._(
      installationId: _id(map['installationId']),
      installationRevision: _revision(map['installationRevision']),
      coreRevision: _revision(map['coreRevision']),
      revision: _revision(map['revision']),
      providers: List.unmodifiable(providers),
      queues: List.unmodifiable(queues),
      receivers: List.unmodifiable(receivers),
      updatedAt: updatedAt,
    );
  }

  final String installationId;
  final int installationRevision, coreRevision, revision;
  final List<ServerMusicProviderBinding> providers;
  final List<ServerMusicQueue> queues;
  final List<ServerMusicReceiver> receivers;
  final DateTime updatedAt;

  Map<String, Object> toJson() => {
    'installationId': installationId,
    'installationRevision': installationRevision,
    'coreRevision': coreRevision,
    'revision': revision,
    'providers': providers.map((item) => item.toJson()).toList(),
    'queues': queues.map((item) => item.toJson()).toList(),
    'receivers': receivers.map((item) => item.toJson()).toList(),
    'installAvailable': false,
    'updatedAt': updatedAt.toIso8601String(),
  };

  ServerMusicQueue? queueFor(ServerMusicReceiver receiver) =>
      receiver.queueId == null
      ? null
      : queues.where((item) => item.id == receiver.queueId).firstOrNull;
}

class ServerMusicCatalogItem {
  const ServerMusicCatalogItem._({
    required this.uri,
    required this.name,
    required this.mediaType,
    required this.providerInstanceId,
    required this.artists,
  });

  factory ServerMusicCatalogItem.fromJson(Object? value) {
    final map = _object(value, {
      'uri',
      'name',
      'mediaType',
      'providerInstanceId',
      'artists',
    });
    if (!_validUri(map['uri'])) _invalid();
    return ServerMusicCatalogItem._(
      uri: map['uri'] as String,
      name: _text(map['name'], max: 512),
      mediaType: _choice(map['mediaType'], {
        'artist',
        'album',
        'track',
        'playlist',
        'radio',
        'audiobook',
        'podcast',
      }),
      providerInstanceId: _binding(map['providerInstanceId']),
      artists: _strings(map['artists'], max: 32),
    );
  }

  final String uri, name, mediaType, providerInstanceId;
  final List<String> artists;
}

class ServerMusicCatalog {
  const ServerMusicCatalog._(this.requestId, this.managerRevision, this.items);
  factory ServerMusicCatalog.fromJson(Object? value) {
    final map = _object(value, {'requestId', 'managerRevision', 'items'});
    if (map['items'] is! List || (map['items'] as List).length > 100) {
      _invalid();
    }
    return ServerMusicCatalog._(
      _id(map['requestId']),
      _revision(map['managerRevision']),
      List.unmodifiable(
        (map['items'] as List).map(ServerMusicCatalogItem.fromJson),
      ),
    );
  }
  final String requestId;
  final int managerRevision;
  final List<ServerMusicCatalogItem> items;
}

class ServerMusicLongformChapter {
  const ServerMusicLongformChapter._({
    required this.position,
    required this.name,
    required this.startSeconds,
    required this.endSeconds,
  });

  factory ServerMusicLongformChapter.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) _invalid();
    const requiredKeys = {'position', 'name', 'startSeconds'};
    const allowedKeys = {...requiredKeys, 'endSeconds'};
    if (!value.keys.toSet().containsAll(requiredKeys) ||
        !allowedKeys.containsAll(value.keys)) {
      _invalid();
    }
    final position = value['position'];
    if (position is! int || position < 0 || position > 10000) _invalid();
    final start = _number(
      value['startSeconds'],
      max: 8640000,
      nullable: false,
    )!;
    final end = value.containsKey('endSeconds')
        ? _number(value['endSeconds'], max: 8640000)
        : null;
    if (end != null && end <= start) _invalid();
    return ServerMusicLongformChapter._(
      position: position,
      name: _text(value['name'], max: 256),
      startSeconds: start,
      endSeconds: end,
    );
  }

  final int position;
  final String name;
  final double startSeconds;
  final double? endSeconds;

  @override
  String toString() => 'ServerMusicLongformChapter($position)';
}

class ServerMusicLongformItem {
  const ServerMusicLongformItem._({
    required this.uri,
    required this.name,
    required this.mediaType,
    required this.providerInstanceId,
    required this.durationSeconds,
    required this.resumePositionSeconds,
    required this.chapters,
  });

  factory ServerMusicLongformItem.fromJson(Object? value) {
    final map = _object(value, {
      'uri',
      'name',
      'mediaType',
      'providerInstanceId',
      'durationSeconds',
      'resumePositionSeconds',
      'fullyPlayed',
      'chapters',
    });
    if (!_validLongformUri(map['uri']) ||
        map['fullyPlayed'] != false ||
        map['chapters'] is! List ||
        (map['chapters'] as List).length > 512) {
      _invalid();
    }
    final duration = _number(
      map['durationSeconds'],
      max: 8640000,
      nullable: false,
    )!;
    final resume = _number(
      map['resumePositionSeconds'],
      max: 8640000,
      nullable: false,
    )!;
    if (duration <= 0 || resume > duration) _invalid();
    final chapters = (map['chapters'] as List)
        .map(ServerMusicLongformChapter.fromJson)
        .toList(growable: false);
    for (var index = 0; index < chapters.length; index++) {
      final chapter = chapters[index];
      final previous = index == 0 ? null : chapters[index - 1];
      if ((previous != null && chapter.position <= previous.position) ||
          chapter.startSeconds >= duration ||
          (chapter.endSeconds != null && chapter.endSeconds! > duration) ||
          (previous != null &&
              (chapter.startSeconds <= previous.startSeconds ||
                  (previous.endSeconds != null &&
                      chapter.startSeconds < previous.endSeconds!)))) {
        _invalid();
      }
    }
    return ServerMusicLongformItem._(
      uri: map['uri'] as String,
      name: _text(map['name'], max: 512),
      mediaType: _choice(map['mediaType'], {'audiobook', 'podcast_episode'}),
      providerInstanceId: _binding(map['providerInstanceId']),
      durationSeconds: duration,
      resumePositionSeconds: resume,
      chapters: List.unmodifiable(chapters),
    );
  }

  final String uri, name, mediaType, providerInstanceId;
  final double durationSeconds, resumePositionSeconds;
  final List<ServerMusicLongformChapter> chapters;

  double get progress => resumePositionSeconds / durationSeconds;

  ServerMusicLongformChapter? get currentChapter {
    ServerMusicLongformChapter? current;
    for (final chapter in chapters) {
      if (chapter.startSeconds > resumePositionSeconds) break;
      if (chapter.endSeconds == null ||
          resumePositionSeconds < chapter.endSeconds!) {
        current = chapter;
      }
    }
    return current;
  }

  @override
  String toString() => 'ServerMusicLongformItem($mediaType)';
}

class ServerMusicLongformCatalog {
  const ServerMusicLongformCatalog._(
    this.requestId,
    this.managerRevision,
    this.items,
  );

  factory ServerMusicLongformCatalog.fromJson(Object? value) {
    final map = _object(value, {'requestId', 'managerRevision', 'items'});
    if (map['items'] is! List || (map['items'] as List).length > 25) {
      _invalid();
    }
    final items = (map['items'] as List)
        .map(ServerMusicLongformItem.fromJson)
        .toList(growable: false);
    if (items.map((item) => item.uri).toSet().length != items.length) {
      _invalid();
    }
    return ServerMusicLongformCatalog._(
      _id(map['requestId']),
      _revision(map['managerRevision']),
      List.unmodifiable(items),
    );
  }

  final String requestId;
  final int managerRevision;
  final List<ServerMusicLongformItem> items;

  @override
  String toString() => 'ServerMusicLongformCatalog(items: ${items.length})';
}

bool _validLongformUri(Object? value) {
  if (value is! String || value.length > 2048) return false;
  final match = RegExp(r'^([a-z][a-z0-9_]{0,63})://[^\s]+$').firstMatch(value);
  if (match == null ||
      const {
        'content',
        'data',
        'file',
        'ftp',
        'http',
        'https',
        'javascript',
      }.contains(match.group(1)) ||
      value.codeUnits.any((unit) => unit < 33 || unit == 127)) {
    return false;
  }
  final parsed = Uri.tryParse(value);
  return parsed != null &&
      parsed.userInfo.isEmpty &&
      !parsed.hasQuery &&
      !parsed.hasFragment;
}

class ServerMusicReceipt {
  const ServerMusicReceipt._({
    required this.requestId,
    required this.targetId,
    required this.operation,
    required this.state,
    required this.playerRevision,
    required this.code,
  });
  factory ServerMusicReceipt.fromJson(Object? value) {
    final map = _object(value, {
      'requestId',
      'targetId',
      'operation',
      'state',
      'playerRevision',
      'code',
      'installAvailable',
    });
    if (map['installAvailable'] != false) _invalid();
    return ServerMusicReceipt._(
      requestId: _id(map['requestId']),
      targetId: _binding(map['targetId']),
      operation: _choice(map['operation'], {
        'play',
        'pause',
        'seek',
        'queue_add',
        'queue_replace',
        'queue_clear',
      }),
      state: _choice(map['state'], {'succeeded', 'needs_attention'}),
      playerRevision: _revision(map['playerRevision']),
      code: _choice(map['code'], {'authenticated_readback', 'effect_unknown'}),
    );
  }
  final String requestId, targetId, operation, state, code;
  final int playerRevision;
  bool get authenticated =>
      state == 'succeeded' && code == 'authenticated_readback';
}
