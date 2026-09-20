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

  Future<ServerMusicManager> read(String installationId) async =>
      ServerMusicManager.fromJson(
        _only(
          await api.request('GET', '$root/$installationId', token: token),
          'manager',
        )['manager'],
      );

  Future<ServerMusicManager> refresh({
    required String requestId,
    required String installationId,
    required int installationRevision,
    required int coreRevision,
  }) async => ServerMusicManager.fromJson(
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

  Future<ServerMusicCatalog> search({
    required String requestId,
    required ServerMusicManager manager,
    required ServerMusicProviderBinding provider,
    required String query,
  }) async => ServerMusicCatalog.fromJson(
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

  Future<ServerMusicReceipt> command({
    required String requestId,
    required ServerMusicManager manager,
    required ServerMusicReceiver receiver,
    required ServerMusicOperation operation,
    double? positionSeconds,
    List<String> mediaUris = const [],
  }) async {
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
    return ServerMusicReceipt.fromJson(
      _only(
        await api.request('POST', '$root/commands', token: token, body: body),
        'receipt',
      )['receipt'],
    );
  }
}
