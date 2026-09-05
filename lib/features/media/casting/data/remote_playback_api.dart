import '../../jellyfin/data/jellyfin_client.dart';
import '../../jellyfin/data/models/jellyfin_item.dart';
import '../domain/remote_playback_models.dart';

abstract interface class RemotePlaybackApi {
  Future<List<RemotePlaybackTarget>> getTargets();
  Future<JellyfinItem> getItem(String itemId);
  Future<void> play({
    required String sessionId,
    required String itemId,
    required Duration startPosition,
  });
}

class JellyfinRemotePlaybackApi implements RemotePlaybackApi {
  const JellyfinRemotePlaybackApi(this.client);
  final JellyfinClient client;
  @override
  Future<List<RemotePlaybackTarget>> getTargets() => client.getRemoteSessions();
  @override
  Future<JellyfinItem> getItem(String itemId) => client.getItem(itemId);
  @override
  Future<void> play({
    required String sessionId,
    required String itemId,
    required Duration startPosition,
  }) => client.playOnSession(
    sessionId: sessionId,
    itemId: itemId,
    startPosition: startPosition,
  );
}
