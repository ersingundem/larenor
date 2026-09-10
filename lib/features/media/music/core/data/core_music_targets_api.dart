import '../../../../server/data/larenor_server_api.dart';
import '../../../../server/data/server_account_controller.dart';
import '../../../../server/domain/server_models.dart';
import '../domain/core_music_target_models.dart';

abstract interface class CoreMusicTargetsApi {
  Future<CoreMusicTargetInventory> read({required bool Function() isCurrent});
}

class AccountCoreMusicTargetsApi implements CoreMusicTargetsApi {
  AccountCoreMusicTargetsApi(this.account) : generation = account.generation;

  final ServerAccountController account;
  final int generation;

  bool get authorized =>
      account.isCurrent(generation) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  @override
  Future<CoreMusicTargetInventory> read({
    required bool Function() isCurrent,
  }) async {
    bool current() => authorized && isCurrent();
    if (!current()) throw const LarenorServerException('forbidden');
    return account.withSession((transport, session) async {
      if (!current() || !session.user.canAdminister) {
        throw const LarenorServerException('cancelled');
      }
      return ServerCoreMusicTargetsApi(
        transport,
        session.accessToken,
      ).read(isCurrent: current);
    });
  }
}

class ServerCoreMusicTargetsApi implements CoreMusicTargetsApi {
  const ServerCoreMusicTargetsApi(this.transport, this.accessToken);

  final LarenorServerApi transport;
  final String accessToken;

  @override
  Future<CoreMusicTargetInventory> read({
    required bool Function() isCurrent,
  }) async {
    try {
      _checkCurrent(isCurrent);
      final retained = _exact(
        await transport.request(
          'GET',
          '/admin/media/music-assistant/retained',
          token: accessToken,
        ),
        const {'schemaVersion', 'state', 'installAvailable', 'installations'},
      );
      final binding = _parseRetained(retained);
      _checkCurrent(isCurrent);

      final playbackEnvelope = _exact(
        await transport.request(
          'GET',
          '/admin/media/music-assistant/playback/${binding.installationId}',
          token: accessToken,
        ),
        const {'playback'},
      );
      final playerRevision = _parsePlayback(
        playbackEnvelope['playback'],
        binding,
      );
      _checkCurrent(isCurrent);

      final body = <String, dynamic>{
        'installationId': binding.installationId,
        'expectedInstallationRevision': binding.installationRevision,
        'expectedCoreRevision': binding.coreRevision,
        'expectedPlayerRevision': playerRevision,
        'expectedProviderRevisions': [
          for (final provider in binding.providers) provider.toJson(),
        ],
      };
      final envelope = _exact(
        await transport.request(
          'POST',
          '/media/music-assistant/target-discovery',
          token: accessToken,
          body: body,
        ),
        const {'inventory'},
      );
      _checkCurrent(isCurrent);
      final inventory = CoreMusicTargetInventory.fromJson(
        envelope['inventory'],
      );
      if (inventory.installationId != binding.installationId ||
          inventory.installationRevision != binding.installationRevision ||
          inventory.coreRevision != binding.coreRevision ||
          inventory.playerRevision != playerRevision ||
          !_sameProviders(inventory.providerRevisions, binding.providers)) {
        throw const CoreMusicTargetsException('stale');
      }
      return inventory;
    } catch (error) {
      throw coreMusicSafeError(error);
    }
  }

  static void _checkCurrent(bool Function() isCurrent) {
    if (!isCurrent()) throw const LarenorServerException('cancelled');
  }

  static _RetainedBinding _parseRetained(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 ||
        json['state'] != 'ready' ||
        json['installAvailable'] != false) {
      throw const CoreMusicTargetsException('not_ready');
    }
    final installations = _boundedList(json['installations'], 64);
    if (installations.length != 1) {
      throw const CoreMusicTargetsException('ambiguous_installation');
    }
    final installation = _exact(installations.single, const {
      'installationId',
      'installationRevision',
      'installationState',
      'state',
      'errorCode',
      'bootstrapReceipt',
      'providers',
    });
    if (installation['state'] != 'ready' ||
        installation['installationState'] != 'container_started' ||
        installation['errorCode'] != null) {
      throw const CoreMusicTargetsException('not_ready');
    }
    final receipt = _exact(installation['bootstrapReceipt'], const {
      'revision',
      'state',
      'serverVersion',
      'schemaVersion',
      'homeAssistant',
      'jellyfin',
    });
    if (receipt['state'] != 'ready') {
      throw const CoreMusicTargetsException('not_ready');
    }
    _parseServiceRevision(receipt['homeAssistant']);
    _parseServiceRevision(receipt['jellyfin']);
    _safeText(receipt['serverVersion'], 80);
    _positive(receipt['schemaVersion']);

    final providers = <CoreMusicProviderRevision>[];
    for (final value in _boundedList(installation['providers'], 256)) {
      final provider = _exact(value, const {
        'id',
        'providerDomain',
        'revision',
        'state',
        'updatedAt',
      });
      _safeDate(provider['updatedAt']);
      if (provider['state'] == 'ready') {
        providers.add(
          CoreMusicProviderRevision.fromJson({
            'id': provider['id'],
            'providerDomain': provider['providerDomain'],
            'revision': provider['revision'],
          }),
        );
      }
    }
    if (providers.isEmpty ||
        providers.map((item) => item.id).toSet().length != providers.length) {
      throw const CoreMusicTargetsException('not_ready');
    }
    return _RetainedBinding(
      installationId: _objectId(installation['installationId']),
      installationRevision: _positive(installation['installationRevision']),
      coreRevision: _positive(receipt['revision']),
      providers: List.unmodifiable(providers),
    );
  }

  static void _parseServiceRevision(Object? value) {
    final json = _exact(value, const {'serviceId', 'serviceRevision'});
    _objectId(json['serviceId']);
    _positive(json['serviceRevision']);
  }

  static int _parsePlayback(Object? value, _RetainedBinding binding) {
    final json = _exact(value, const {
      'installationId',
      'installationRevision',
      'coreRevision',
      'revision',
      'players',
      'installAvailable',
      'updatedAt',
    });
    if (json['installAvailable'] != false ||
        _objectId(json['installationId']) != binding.installationId ||
        _positive(json['installationRevision']) !=
            binding.installationRevision ||
        _positive(json['coreRevision']) != binding.coreRevision) {
      throw const CoreMusicTargetsException('stale');
    }
    _safeDate(json['updatedAt']);
    for (final value in _boundedList(json['players'], 256)) {
      _validatePlayer(value);
    }
    return _positive(json['revision']);
  }

  static void _validatePlayer(Object? value) {
    final json = _exact(value, const {
      'playerId',
      'name',
      'provider',
      'providerDomain',
      'providerInstanceId',
      'targetKind',
      'available',
      'enabled',
      'playbackState',
      'volumeLevel',
      'muted',
      'groupMembers',
      'queueId',
      'queue',
      'capabilities',
    });
    _safeId(json['playerId']);
    _safeText(json['name'], 160);
    final provider = _safeId(json['provider']);
    if (_safeText(json['providerDomain'], 64) != provider.split('--').first ||
        _safeId(json['providerInstanceId']) != provider ||
        !const {
          'homepod',
          'airplay',
          'airplay_group',
          'chromecast',
          'chromecast_group',
          'group',
          'other',
        }.contains(json['targetKind']) ||
        json['available'] is! bool ||
        json['enabled'] is! bool ||
        !const {'idle', 'playing', 'paused'}.contains(json['playbackState']) ||
        (json['volumeLevel'] != null &&
            (json['volumeLevel'] is! int ||
                (json['volumeLevel'] as int) < 0 ||
                (json['volumeLevel'] as int) > 100)) ||
        (json['muted'] != null && json['muted'] is! bool)) {
      throw const CoreMusicTargetsException('invalid_response');
    }
    final members = _boundedList(
      json['groupMembers'],
      64,
    ).map(_safeId).toList(growable: false);
    final grouped = const {
      'airplay_group',
      'chromecast_group',
      'group',
    }.contains(json['targetKind']);
    if (grouped != members.isNotEmpty ||
        members.toSet().length != members.length) {
      throw const CoreMusicTargetsException('invalid_response');
    }
    final queueId = json['queueId'] == null ? null : _safeId(json['queueId']);
    final queue = json['queue'] == null
        ? null
        : CoreMusicQueue.fromJson(json['queue']);
    if (queue != null && queue.id != queueId) {
      throw const CoreMusicTargetsException('invalid_response');
    }
    final capabilities = _boundedList(json['capabilities'], 8);
    const allowed = {
      'play',
      'pause',
      'stop',
      'seek',
      'next_previous',
      'volume_set',
      'volume_mute',
      'queue',
    };
    if (capabilities.any((item) => !allowed.contains(item)) ||
        capabilities.toSet().length != capabilities.length) {
      throw const CoreMusicTargetsException('invalid_response');
    }
  }

  static bool _sameProviders(
    List<CoreMusicProviderRevision> left,
    List<CoreMusicProviderRevision> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.id != b.id ||
          a.providerDomain != b.providerDomain ||
          a.revision != b.revision) {
        return false;
      }
    }
    return true;
  }
}

class _RetainedBinding {
  const _RetainedBinding({
    required this.installationId,
    required this.installationRevision,
    required this.coreRevision,
    required this.providers,
  });
  final String installationId;
  final int installationRevision;
  final int coreRevision;
  final List<CoreMusicProviderRevision> providers;
}

Map<String, dynamic> _exact(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const CoreMusicTargetsException('invalid_response');
  }
  return value;
}

List<dynamic> _boundedList(Object? value, int max) {
  if (value is! List<dynamic> || value.length > max) {
    throw const CoreMusicTargetsException('invalid_response');
  }
  return value;
}

String _safeText(Object? value, int max) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const CoreMusicTargetsException('invalid_response');
  }
  return value;
}

String _safeId(Object? value) {
  final text = _safeText(value, 128);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$').hasMatch(text)) {
    throw const CoreMusicTargetsException('invalid_response');
  }
  return text;
}

String _objectId(Object? value) {
  final text = _safeText(value, 32);
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(text)) {
    throw const CoreMusicTargetsException('invalid_response');
  }
  return text;
}

int _positive(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) {
    throw const CoreMusicTargetsException('invalid_response');
  }
  return value;
}

DateTime _safeDate(Object? value) {
  final text = _safeText(value, 40);
  final parsed = DateTime.tryParse(text);
  if (parsed == null || !parsed.isUtc) {
    throw const CoreMusicTargetsException('invalid_response');
  }
  return parsed;
}
