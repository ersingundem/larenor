import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../media_preparations/domain/server_media_preparation_models.dart';
import '../domain/server_music_provider_command_models.dart';

class ServerMusicProviderCommandsApi {
  const ServerMusicProviderCommandsApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;
  static const root = '/admin/media/music-assistant/provider-commands';

  Future<ServerMusicProviderCommandPreview> preview(
    ServerMusicProviderCommandIntent intent,
  ) async {
    final response = mediaObject(
      await api.request(
        'POST',
        '$root/previews',
        token: token,
        body: intent.toJson(),
      ),
      {'preview'},
    );
    final value = ServerMusicProviderCommandPreview.fromJson(
      response['preview'],
    );
    if (!intent.accepts(value)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  Future<ServerMusicProviderCommand> confirm({
    required ServerMusicProviderCommandPreview preview,
    required String requestId,
  }) async {
    mediaId(requestId);
    final response = mediaObject(
      await api.request(
        'POST',
        root,
        token: token,
        body: {
          'requestId': requestId,
          'previewId': preview.id,
          'expectedPreviewRevision': preview.revision,
          'planHash': preview.planHash,
        },
      ),
      {'command'},
    );
    final value = ServerMusicProviderCommand.fromJson(response['command']);
    if (value.requestId != requestId ||
        value.previewId != preview.id ||
        value.installationId != preview.installationId ||
        value.installationRevision != preview.installationRevision ||
        value.providerSetupId != preview.providerSetupId ||
        value.providerRevision != preview.providerRevision ||
        value.providerDomain != preview.providerDomain ||
        value.command != preview.command ||
        value.createdAt.isBefore(preview.createdAt)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }
}
