import '../../data/larenor_server_api.dart';
import '../domain/server_music_retained_models.dart';

class ServerMusicRetainedApi {
  const ServerMusicRetainedApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;

  Future<ServerMusicRetainedOverview> read() async =>
      ServerMusicRetainedOverview.fromJson(
        await api.request(
          'GET',
          '/admin/media/music-assistant/retained',
          token: token,
        ),
      );
}
