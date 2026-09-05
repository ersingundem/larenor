import 'dart:async';

import 'package:larenor/features/media/casting/data/remote_playback_api.dart';
import 'package:larenor/features/media/casting/data/remote_playback_controller.dart';
import 'package:larenor/features/media/casting/domain/remote_playback_models.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';

const userId = '11111111111111111111111111111111';
const otherUserId = '22222222222222222222222222222222';
const itemId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const otherItemId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final remoteNow = DateTime.utc(2026, 9, 5, 12);
Map<String, dynamic> targetJson({
  String id = 'remote-session',
  String user = userId,
  String device = 'television',
  String server = 'server-one',
  String? nowPlaying,
  bool? paused = false,
}) => {
  'Id': id,
  'UserId': user,
  'DeviceId': device,
  'ServerId': server,
  'DeviceName': 'Living room TV',
  'Client': 'Jellyfin TV',
  'IsActive': true,
  'SupportsRemoteControl': true,
  'SupportsMediaControl': true,
  'PlayableMediaTypes': ['Video'],
  'PlayState': {'IsPaused': paused, 'PositionTicks': 0},
  if (nowPlaying != null) 'NowPlayingItem': {'Id': nowPlaying},
  'LastPlaybackCheckIn': remoteNow.toIso8601String(),
};
RemotePlaybackTarget target({
  String id = 'remote-session',
  String user = userId,
  String device = 'television',
  String server = 'server-one',
  String? nowPlaying,
  bool? paused = false,
}) => parseRemotePlaybackTargets([
  targetJson(
    id: id,
    user: user,
    device: device,
    server: server,
    nowPlaying: nowPlaying,
    paused: paused,
  ),
]).single;
const playableItem = JellyfinItem(
  id: itemId,
  name: 'Confirmed movie',
  type: 'Movie',
  locationType: 'FileSystem',
  playAccess: 'Full',
  runTimeTicks: 36000000000,
);

class FakeRemoteApi implements RemotePlaybackApi {
  List<RemotePlaybackTarget> targets = [target()];
  JellyfinItem item = playableItem;
  Completer<void>? targetGate, itemGate, playGate;
  Object? targetError, itemError, playError;
  int reads = 0, itemReads = 0;
  final commands = <({String sessionId, String itemId, Duration position})>[];
  @override
  Future<List<RemotePlaybackTarget>> getTargets() async {
    reads++;
    await targetGate?.future;
    if (targetError != null) throw targetError!;
    return List.of(targets);
  }

  @override
  Future<JellyfinItem> getItem(String itemId) async {
    itemReads++;
    await itemGate?.future;
    if (itemError != null) throw itemError!;
    return item;
  }

  @override
  Future<void> play({
    required String sessionId,
    required String itemId,
    required Duration startPosition,
  }) async {
    commands.add((
      sessionId: sessionId,
      itemId: itemId,
      position: startPosition,
    ));
    await playGate?.future;
    if (playError != null) throw playError!;
  }
}

RemotePlaybackController remoteController(
  FakeRemoteApi api, {
  DateTime Function()? now,
  bool Function()? isCurrent,
}) => RemotePlaybackController(
  api: api,
  userId: userId,
  localDeviceId: 'local-tablet',
  isCurrent: isCurrent ?? () => true,
  now: now ?? () => remoteNow,
);
