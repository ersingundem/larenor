import '../../../../server/domain/server_models.dart';

class CoreMusicTargetsException implements Exception {
  const CoreMusicTargetsException(this.code);
  final String code;

  @override
  String toString() => 'CoreMusicTargetsException($code)';
}

Never _invalid() => throw const CoreMusicTargetsException('invalid_response');

String _objectId(Object? value) {
  final id = _text(value, max: 32);
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) _invalid();
  return id;
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

List<dynamic> _list(Object? value, {required int max}) {
  if (value is! List<dynamic> || value.length > max) _invalid();
  return value;
}

String _text(Object? value, {required int max, bool identifier = false}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      (identifier &&
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$').hasMatch(value))) {
    _invalid();
  }
  return value;
}

int _integer(Object? value, {int min = 0, int max = 0x7fffffffffffffff}) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

bool _boolean(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

T _oneOf<T>(Object? value, Map<String, T> values) {
  if (value is! String || !values.containsKey(value)) _invalid();
  return values[value] as T;
}

class CoreMusicProviderRevision {
  const CoreMusicProviderRevision({
    required this.id,
    required this.providerDomain,
    required this.revision,
  });

  factory CoreMusicProviderRevision.fromJson(Object? value) {
    final json = _object(value, {'id', 'providerDomain', 'revision'});
    final domain = _text(json['providerDomain'], max: 64);
    if (!RegExp(r'^[a-z0-9][a-z0-9_]{0,63}$').hasMatch(domain)) _invalid();
    return CoreMusicProviderRevision(
      id: _objectId(json['id']),
      providerDomain: domain,
      revision: _integer(json['revision'], min: 1),
    );
  }

  final String id;
  final String providerDomain;
  final int revision;

  Map<String, Object> toJson() => {
    'id': id,
    'providerDomain': providerDomain,
    'revision': revision,
  };
}

class CoreMusicNowPlaying {
  const CoreMusicNowPlaying({
    required this.itemId,
    required this.title,
    required this.durationSeconds,
    required this.positionSeconds,
  });

  factory CoreMusicNowPlaying.fromJson(Object? value) {
    final json = _object(value, {
      'itemId',
      'title',
      'durationSeconds',
      'positionSeconds',
    });
    final duration = json['durationSeconds'] == null
        ? null
        : _integer(json['durationSeconds'], max: 604800);
    final position = _integer(json['positionSeconds'], max: 604800);
    if (duration != null && position > duration) _invalid();
    return CoreMusicNowPlaying(
      itemId: _text(json['itemId'], max: 128, identifier: true),
      title: _text(json['title'], max: 320),
      durationSeconds: duration,
      positionSeconds: position,
    );
  }

  final String itemId;
  final String title;
  final int? durationSeconds;
  final int positionSeconds;
}

class CoreMusicQueue {
  const CoreMusicQueue({
    required this.id,
    required this.active,
    required this.available,
    required this.itemCount,
    required this.currentIndex,
    required this.shuffleEnabled,
    required this.repeatMode,
    required this.state,
    required this.nowPlaying,
  });

  factory CoreMusicQueue.fromJson(Object? value) {
    final json = _object(value, {
      'id',
      'active',
      'available',
      'itemCount',
      'currentIndex',
      'shuffleEnabled',
      'repeatMode',
      'state',
      'nowPlaying',
    });
    final count = _integer(json['itemCount'], max: 100000);
    final index = json['currentIndex'] == null
        ? null
        : _integer(json['currentIndex'], max: 99999);
    final nowPlaying = json['nowPlaying'] == null
        ? null
        : CoreMusicNowPlaying.fromJson(json['nowPlaying']);
    if ((index == null) != (nowPlaying == null) ||
        (index != null && index >= count)) {
      _invalid();
    }
    return CoreMusicQueue(
      id: _text(json['id'], max: 128, identifier: true),
      active: _boolean(json['active']),
      available: _boolean(json['available']),
      itemCount: count,
      currentIndex: index,
      shuffleEnabled: _boolean(json['shuffleEnabled']),
      repeatMode: _oneOf(json['repeatMode'], const {
        'off': 'off',
        'one': 'one',
        'all': 'all',
      }),
      state: _oneOf(json['state'], const {
        'idle': 'idle',
        'playing': 'playing',
        'paused': 'paused',
      }),
      nowPlaying: nowPlaying,
    );
  }

  final String id;
  final bool active;
  final bool available;
  final int itemCount;
  final int? currentIndex;
  final bool shuffleEnabled;
  final String repeatMode;
  final String state;
  final CoreMusicNowPlaying? nowPlaying;
  int get positionSeconds => nowPlaying?.positionSeconds ?? 0;
}

enum CoreMusicTransport { airplay, chromecast }

enum CoreMusicTargetKind { device, group }

class CoreMusicTarget {
  const CoreMusicTarget({
    required this.id,
    required this.name,
    required this.providerDomain,
    required this.providerInstanceId,
    required this.transport,
    required this.kind,
    required this.homePod,
    required this.available,
    required this.enabled,
    required this.playbackState,
    required this.volumeLevel,
    required this.muted,
    required this.groupMemberIds,
    required this.queueId,
    required this.queue,
    required this.capabilities,
  });

  factory CoreMusicTarget.fromJson(Object? value) {
    final json = _object(value, {
      'id',
      'name',
      'provider',
      'providerDomain',
      'providerInstanceId',
      'transport',
      'kind',
      'homePod',
      'available',
      'enabled',
      'playbackState',
      'volumeLevel',
      'muted',
      'groupMemberIds',
      'queueId',
      'queue',
      'capabilities',
    });
    final provider = _text(json['provider'], max: 128, identifier: true);
    final providerDomain = _text(json['providerDomain'], max: 64);
    final providerInstance = _text(
      json['providerInstanceId'],
      max: 128,
      identifier: true,
    );
    final transport = _oneOf(json['transport'], const {
      'airplay': CoreMusicTransport.airplay,
      'chromecast': CoreMusicTransport.chromecast,
    });
    final kind = _oneOf(json['kind'], const {
      'device': CoreMusicTargetKind.device,
      'group': CoreMusicTargetKind.group,
    });
    final members = _list(json['groupMemberIds'], max: 64)
        .map((item) => _text(item, max: 128, identifier: true))
        .toList(growable: false);
    final homePod = _boolean(json['homePod']);
    final queueId = json['queueId'] == null
        ? null
        : _text(json['queueId'], max: 128, identifier: true);
    final queue = json['queue'] == null
        ? null
        : CoreMusicQueue.fromJson(json['queue']);
    final capabilities = _list(json['capabilities'], max: 8)
        .map(
          (item) => _oneOf(item, const {
            'play': 'play',
            'pause': 'pause',
            'stop': 'stop',
            'seek': 'seek',
            'next_previous': 'next_previous',
            'volume_set': 'volume_set',
            'volume_mute': 'volume_mute',
            'queue': 'queue',
          }),
        )
        .toList(growable: false);
    if (provider != providerInstance ||
        providerDomain != provider.split('--').first ||
        (kind == CoreMusicTargetKind.group) != members.isNotEmpty ||
        homePod &&
            (transport != CoreMusicTransport.airplay ||
                kind != CoreMusicTargetKind.device) ||
        members.toSet().length != members.length ||
        capabilities.toSet().length != capabilities.length ||
        (queue != null && queue.id != queueId)) {
      _invalid();
    }
    return CoreMusicTarget(
      id: _text(json['id'], max: 128, identifier: true),
      name: _text(json['name'], max: 160),
      providerDomain: providerDomain,
      providerInstanceId: providerInstance,
      transport: transport,
      kind: kind,
      homePod: homePod,
      available: _boolean(json['available']),
      enabled: _boolean(json['enabled']),
      playbackState: _oneOf(json['playbackState'], const {
        'idle': 'idle',
        'playing': 'playing',
        'paused': 'paused',
      }),
      volumeLevel: json['volumeLevel'] == null
          ? null
          : _integer(json['volumeLevel'], max: 100),
      muted: json['muted'] == null ? null : _boolean(json['muted']),
      groupMemberIds: List.unmodifiable(members),
      queueId: queueId,
      queue: queue,
      capabilities: List.unmodifiable(capabilities),
    );
  }

  final String id;
  final String name;
  final String providerDomain;
  final String providerInstanceId;
  final CoreMusicTransport transport;
  final CoreMusicTargetKind kind;
  final bool homePod;
  final bool available;
  final bool enabled;
  final String playbackState;
  final int? volumeLevel;
  final bool? muted;
  final List<String> groupMemberIds;
  final String? queueId;
  final CoreMusicQueue? queue;
  final List<String> capabilities;
}

class CoreMusicTargetInventory {
  const CoreMusicTargetInventory({
    required this.installationId,
    required this.installationRevision,
    required this.coreRevision,
    required this.playerRevision,
    required this.providerRevisions,
    required this.targets,
    required this.updatedAt,
  });

  factory CoreMusicTargetInventory.fromJson(Object? value) {
    final json = _object(value, {
      'installationId',
      'installationRevision',
      'coreRevision',
      'playerRevision',
      'providerRevisions',
      'targets',
      'installAvailable',
      'updatedAt',
    });
    if (json['installAvailable'] != false) _invalid();
    final providers = _list(
      json['providerRevisions'],
      max: 256,
    ).map(CoreMusicProviderRevision.fromJson).toList(growable: false);
    final targets = _list(
      json['targets'],
      max: 256,
    ).map(CoreMusicTarget.fromJson).toList(growable: false);
    if (providers.map((item) => item.id).toSet().length != providers.length ||
        targets.map((item) => item.id).toSet().length != targets.length) {
      _invalid();
    }
    return CoreMusicTargetInventory(
      installationId: _objectId(json['installationId']),
      installationRevision: _integer(json['installationRevision'], min: 1),
      coreRevision: _integer(json['coreRevision'], min: 1),
      playerRevision: _integer(json['playerRevision'], min: 1),
      providerRevisions: List.unmodifiable(providers),
      targets: List.unmodifiable(targets),
      updatedAt: DateTime.parse(_text(json['updatedAt'], max: 40)).toUtc(),
    );
  }

  final String installationId;
  final int installationRevision;
  final int coreRevision;
  final int playerRevision;
  final List<CoreMusicProviderRevision> providerRevisions;
  final List<CoreMusicTarget> targets;
  final DateTime updatedAt;

  @override
  String toString() =>
      'CoreMusicTargetInventory(targets: ${targets.length}, revision: $playerRevision)';
}

LarenorServerException coreMusicSafeError(Object error) =>
    LarenorServerException(
      error is LarenorServerException
          ? error.code
          : error is CoreMusicTargetsException
          ? error.code
          : 'invalid_response',
    );
