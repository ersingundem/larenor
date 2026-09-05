import 'dart:async';

import 'package:larenor/features/media/ha_playback/data/ha_playback_api.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_media_inventory.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';

final playbackNow = DateTime.utc(2026, 9, 5, 10);
const mediaSource = 'media-source://media_source/local/test.mp3';
Map<String, dynamic> browseNode({
  String id = mediaSource,
  String title = 'Test audio',
  String type = 'audio/mpeg',
  bool play = true,
  bool expand = false,
}) => {
  'media_content_id': id,
  'title': title,
  'media_content_type': type,
  'media_class': play ? 'music' : 'directory',
  'can_play': play,
  'can_expand': expand,
};
Map<String, dynamic> browseRaw({
  String parent = 'media-source://',
  List<Object?>? children,
}) => {
  ...browseNode(
    id: parent,
    title: 'Sources',
    type: 'directory',
    play: false,
    expand: true,
  ),
  'children': children ?? [browseNode()],
  'not_shown': 0,
};
Map<String, dynamic> stateRaw({
  String id = 'media_player.living',
  String state = 'idle',
  String? contentId,
  int features = 512,
  String deviceClass = 'speaker',
  DateTime? updated,
}) => {
  'entity_id': id,
  'state': state,
  'last_updated': (updated ?? playbackNow).toIso8601String(),
  'attributes': <String, dynamic>{
    'friendly_name': 'Living room',
    'supported_features': features,
    'device_class': deviceClass,
    'media_content_id': ?contentId,
  },
};
Map<String, dynamic> registryRaw({
  String id = 'media_player.living',
  String registry = 'registered',
  String platform = 'cast',
}) => {
  'entity_id': id,
  'id': registry,
  'platform': platform,
  'device_id': 'device',
  'config_entry_id': 'entry',
  'disabled_by': null,
  'hidden_by': null,
};
Map<String, dynamic> get mediaServices => {
  'media_player': {
    'play_media': {
      'fields': {
        'media': {'required': true},
      },
    },
  },
};
HaMediaInventory inventory({
  Map<String, dynamic>? state,
  Map<String, dynamic>? registry,
  Map<String, dynamic>? services,
}) => parseHaMediaInventory(
  states: [state ?? stateRaw()],
  services: services ?? mediaServices,
  registry: [registry ?? registryRaw()],
  readAt: playbackNow,
);

class FakeHaPlaybackApi extends HaPlaybackApi {
  HaMediaInventory currentInventory = inventory();
  Map<String, HaMediaBrowsePage> pages = {
    'media-source://': parseHaMediaBrowse(browseRaw(), playbackNow),
  };
  final commands = <({String entityId, HaMediaNode source})>[];
  final browseIds = <String?>[];
  int inventoryReads = 0;
  Future<void> Function()? inventoryGate, browseGate, playGate;
  Object? inventoryError, browseError, playError;
  final connections = StreamController<bool>.broadcast();
  @override
  Stream<bool> get connectionChanges => Stream.multi((sink) {
    final sub = connections.stream.listen(sink.add);
    sink.add(true);
    sink.onCancel = sub.cancel;
  });
  @override
  Future<HaMediaInventory> getInventory() async {
    inventoryReads++;
    await inventoryGate?.call();
    if (inventoryError != null) throw inventoryError!;
    return currentInventory;
  }

  @override
  Future<HaMediaBrowsePage> browse(String? id) async {
    browseIds.add(id);
    await browseGate?.call();
    if (browseError != null) throw browseError!;
    return pages[id ?? 'media-source://']!;
  }

  @override
  Future<void> play({
    required String entityId,
    required HaMediaNode source,
    required bool Function() isCurrent,
  }) async {
    await playGate?.call();
    if (!isCurrent()) {
      throw const HaPlaybackException(HaPlaybackFailure.invalidIntent);
    }
    commands.add((entityId: entityId, source: source));
    if (playError != null) throw playError!;
  }

  void dispose() {
    unawaited(connections.close());
  }
}

Future<void> drain() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
