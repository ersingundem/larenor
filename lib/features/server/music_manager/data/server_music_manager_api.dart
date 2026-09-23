import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_manager_models.dart';

class ServerMusicManagerApi {
  const ServerMusicManagerApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;
  static const root = '/admin/media/music-assistant/manager';

  Map<String, dynamic> _only(Object? value, String key) {
    final result = serverObject(value);
    if (result.length != 1 || !result.containsKey(key)) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  }

  Future<ServerMusicManager> read(String installationId) async {
    _id(installationId);
    final value = ServerMusicManager.fromJson(
      _only(
        await api.request('GET', '$root/$installationId', token: token),
        'manager',
      )['manager'],
    );
    if (value.installationId != installationId) _invalidResponse();
    return value;
  }

  Future<ServerMusicManager> refresh({
    required String requestId,
    required String installationId,
    required int installationRevision,
    required int coreRevision,
  }) async {
    _id(requestId);
    _id(installationId);
    _revision(installationRevision);
    _revision(coreRevision);
    final value = ServerMusicManager.fromJson(
      _only(
        await api.request(
          'POST',
          '$root/refresh',
          token: token,
          body: {
            'requestId': requestId,
            'installationId': installationId,
            'expectedInstallationRevision': installationRevision,
            'expectedCoreRevision': coreRevision,
          },
        ),
        'manager',
      )['manager'],
    );
    if (value.installationId != installationId ||
        value.installationRevision != installationRevision ||
        value.coreRevision != coreRevision) {
      _invalidResponse();
    }
    return value;
  }

  Future<ServerMusicCatalog> search({
    required String requestId,
    required ServerMusicManager manager,
    required ServerMusicProviderBinding provider,
    required String query,
  }) async {
    _id(requestId);
    if (!_validQuery(query) ||
        !manager.providers.any((value) => _sameProvider(value, provider))) {
      _invalidRequest();
    }
    final value = ServerMusicCatalog.fromJson(
      _only(
        await api.request(
          'POST',
          '$root/catalog/search',
          token: token,
          body: {
            'requestId': requestId,
            'installationId': manager.installationId,
            'expectedInstallationRevision': manager.installationRevision,
            'expectedCoreRevision': manager.coreRevision,
            'expectedManagerRevision': manager.revision,
            'providerSetupId': provider.setupId,
            'expectedProviderRevision': provider.revision,
            'providerDomain': provider.domain,
            'providerInstanceId': provider.instanceId,
            'query': query,
            'mediaTypes': const [
              'artist',
              'album',
              'track',
              'playlist',
              'radio',
              'audiobook',
              'podcast',
            ],
            'limit': 25,
            'libraryOnly': false,
          },
        ),
        'catalog',
      )['catalog'],
    );
    if (value.requestId != requestId ||
        value.managerRevision != manager.revision ||
        value.items.any(
          (item) => item.providerInstanceId != provider.instanceId,
        )) {
      _invalidResponse();
    }
    return value;
  }

  Future<ServerMusicReceipt> command({
    required String requestId,
    required ServerMusicManager manager,
    required ServerMusicReceiver receiver,
    required ServerMusicOperation operation,
    double? positionSeconds,
    List<String> mediaUris = const [],
  }) async {
    _id(requestId);
    final queueOperation = {
      ServerMusicOperation.queueAdd,
      ServerMusicOperation.queueReplace,
    }.contains(operation);
    final exactReceiver = manager.receivers.any(
      (value) => _sameReceiver(value, receiver),
    );
    final validMedia =
        mediaUris.isNotEmpty &&
        mediaUris.length <= 64 &&
        mediaUris.every(_validMediaUri);
    final validSeek =
        positionSeconds != null &&
        positionSeconds.isFinite &&
        positionSeconds >= 0 &&
        positionSeconds <= 864000;
    if (!exactReceiver ||
        !receiver.available ||
        !receiver.enabled ||
        !receiver.supports(operation) ||
        (queueOperation && !validMedia) ||
        (!queueOperation && mediaUris.isNotEmpty) ||
        (operation == ServerMusicOperation.seek && !validSeek) ||
        (operation != ServerMusicOperation.seek && positionSeconds != null)) {
      _invalidRequest();
    }
    final body = <String, dynamic>{
      'requestId': requestId,
      'installationId': manager.installationId,
      'expectedInstallationRevision': manager.installationRevision,
      'expectedCoreRevision': manager.coreRevision,
      'expectedPlayerRevision': manager.revision,
      'targetId': receiver.id,
      'expectedProvider': receiver.provider,
      'expectedTargetKind': receiver.kind,
      'expectedQueueId': receiver.queueId,
      'expectedGroupMembers': receiver.groupMembers,
      'operation': operation.wire,
    };
    if (operation == ServerMusicOperation.seek) {
      body['positionSeconds'] = positionSeconds;
    }
    if ({
      ServerMusicOperation.queueAdd,
      ServerMusicOperation.queueReplace,
    }.contains(operation)) {
      body['mediaUris'] = mediaUris;
    }
    final value = ServerMusicReceipt.fromJson(
      _only(
        await api.request('POST', '$root/commands', token: token, body: body),
        'receipt',
      )['receipt'],
    );
    if (value.requestId != requestId ||
        value.targetId != receiver.id ||
        value.operation != operation.wire) {
      _invalidResponse();
    }
    return value;
  }
}

Never _invalidRequest() =>
    throw const LarenorServerException('invalid_request');

Never _invalidResponse() =>
    throw const LarenorServerException('invalid_response');

void _id(String value) {
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) _invalidRequest();
}

void _revision(int value) {
  if (value < 1 || value > 0x7fffffffffffffff) _invalidRequest();
}

bool _validQuery(String value) =>
    value.isNotEmpty &&
    value.length <= 160 &&
    value == value.trim() &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

bool _validMediaUri(String value) =>
    value.isNotEmpty &&
    value.length <= 2048 &&
    RegExp(r'^(?:spotify|apple_music|ytmusic|library)://[^\s]+$')
        .hasMatch(value);

bool _sameProvider(
  ServerMusicProviderBinding left,
  ServerMusicProviderBinding right,
) =>
    left.setupId == right.setupId &&
    left.revision == right.revision &&
    left.domain == right.domain &&
    left.instanceId == right.instanceId;

bool _sameReceiver(ServerMusicReceiver left, ServerMusicReceiver right) {
  if (left.id != right.id ||
      left.name != right.name ||
      left.provider != right.provider ||
      left.kind != right.kind ||
      left.available != right.available ||
      left.enabled != right.enabled ||
      left.playbackState != right.playbackState ||
      left.volumeLevel != right.volumeLevel ||
      left.muted != right.muted ||
      left.queueId != right.queueId ||
      left.positionSeconds != right.positionSeconds ||
      !_sameStrings(left.groupMembers, right.groupMembers) ||
      !_sameStrings(left.capabilities, right.capabilities)) {
    return false;
  }
  return true;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
