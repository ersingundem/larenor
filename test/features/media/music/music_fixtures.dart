import 'dart:async';

import 'package:larenor/features/media/ha_playback/domain/ha_media_inventory.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';
import 'package:larenor/features/media/music/data/music_api.dart';
import 'package:larenor/features/media/music/domain/music_models.dart';

final musicTime = DateTime.utc(2026, 9, 5, 12);
List<Map<String, Object?>> musicEntries({
  String id = 'entry',
  String state = 'loaded',
  Object? disabled,
}) => [
  {
    'entry_id': id,
    'title': 'Home music',
    'domain': 'music_assistant',
    'state': state,
    'disabled_by': disabled,
  },
];
HaMediaInventory musicInventory({
  bool registry = true,
  HaPlaybackFailure? registryFailure,
  String entry = 'entry',
  String platform = 'music_assistant',
  bool available = true,
  bool enabled = true,
  bool queueService = true,
  DateTime? readAt,
}) => HaMediaInventory(
  targets: [
    HaMediaTarget(
      entityId: 'media_player.kitchen',
      name: 'Kitchen',
      state: available ? 'idle' : 'unavailable',
      supportedFeatures: 512,
      enabled: enabled,
      platform: platform,
      registryId: 'registry',
      configEntryId: entry,
    ),
  ],
  services: {
    'music_assistant': {
      'get_library': {
        'response': {'optional': false},
      },
      'search': {
        'response': {'optional': false},
      },
      if (queueService)
        'get_queue': {
          'response': {'optional': false},
        },
    },
  },
  readAt: readAt ?? musicTime,
  registryAvailable: registry,
  registryFailure: registryFailure,
);
Map<String, Object?> musicItem({
  MusicMediaType type = MusicMediaType.track,
  String name = 'Song',
}) => {
  'media_type': type.name,
  'uri': 'library://${type.name}/123',
  'name': name,
  'version': '',
  'image': null,
};
Map<String, Object?> musicLibrary(MusicLibraryQuery query) => {
  'items': [musicItem(type: query.type)],
  'limit': query.limit,
  'offset': query.offset,
  'order_by': 'name',
  'media_type': query.type.name,
};
Map<String, Object?> musicSearch() => {
  'artists': [],
  'albums': [],
  'tracks': [musicItem()],
  'playlists': [],
  'radio': [],
  'audiobooks': [],
  'podcasts': [],
};
Map<String, Object?> musicQueue({
  String entity = 'media_player.kitchen',
  int count = 2,
}) => {
  entity: {
    'queue_id': 'queue',
    'name': 'Kitchen queue',
    'active': true,
    'items': count,
    'shuffle_enabled': false,
    'repeat_mode': 'off',
    'current_index': count > 0 ? 0 : null,
    'elapsed_time': 12,
    'current_item': count == 0
        ? null
        : {
            'queue_item_id': 'q1',
            'name': 'Song',
            'duration': 180,
            'media_item': musicItem(),
            'stream_title': null,
          },
    'next_item': null,
  },
};

class FakeMusicApi implements MusicAssistantApi {
  Object? entries = musicEntries(), entriesError, libraryError, queueError;
  Completer<Object?>? entriesGate, libraryGate, queueGate;
  int entryReads = 0, libraryReads = 0, searchReads = 0, queueReads = 0;
  @override
  Future<Object?> configEntries({required bool Function() isCurrent}) async {
    if (!isCurrent()) throw const MusicException(MusicFailure.stale);
    entryReads++;
    if (entriesError != null) throw entriesError!;
    return entriesGate != null ? await entriesGate!.future : entries;
  }

  @override
  Future<Object?> library(
    MusicLibraryQuery query, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const MusicException(MusicFailure.stale);
    libraryReads++;
    if (libraryError != null) throw libraryError!;
    return libraryGate != null
        ? await libraryGate!.future
        : musicLibrary(query);
  }

  @override
  Future<Object?> search(
    MusicSearchQuery query, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const MusicException(MusicFailure.stale);
    searchReads++;
    return musicSearch();
  }

  @override
  Future<Object?> queue(
    String entityId, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const MusicException(MusicFailure.stale);
    queueReads++;
    if (queueError != null) throw queueError!;
    return queueGate != null
        ? await queueGate!.future
        : musicQueue(entity: entityId);
  }
}
