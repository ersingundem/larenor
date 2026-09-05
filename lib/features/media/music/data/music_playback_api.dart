import '../../../ha_client/data/ws_client.dart';
import '../domain/music_models.dart';

abstract class MusicPlaybackApi {
  Stream<bool> get connectionChanges => Stream.value(true);
  Future<void> play({
    required String entityId,
    required MusicMediaItem item,
    required bool Function() isCurrent,
  });
}

class WsMusicPlaybackApi extends MusicPlaybackApi {
  WsMusicPlaybackApi(this.ws);
  final HaWebSocketClient ws;
  @override
  Stream<bool> get connectionChanges => ws.status
      .map((state) => state == HaConnectionStatus.connected)
      .distinct();
  @override
  Future<void> play({
    required String entityId,
    required MusicMediaItem item,
    required bool Function() isCurrent,
  }) async {
    // MA PLAY inserts at the current position and starts playback. REPLACE
    // clears the entire queue and is intentionally not used by "Play now".
    await ws.callService(
      'music_assistant',
      'play_media',
      serviceData: {
        'media_id': [item.reference.requestValue],
        'media_type': item.type.name,
        'enqueue': 'play',
      },
      target: {
        'entity_id': [entityId],
      },
      isCurrent: isCurrent,
    );
  }
}
