import '../domain/music_models.dart';

Never _invalid() => throw const MusicException(MusicFailure.invalidResponse);
Never _large() => throw const MusicException(MusicFailure.tooLarge);

// Validate even discarded metadata, without serializing private response bodies.
void validateMusicPayload(Object? value) {
  var nodes = 0, textUnits = 0;
  void walk(Object? item, int depth) {
    if (++nodes > 40000 || depth > 12) _large();
    if (item is Map) {
      if (item.length > 2000) _large();
      for (final entry in item.entries) {
        if (entry.key is! String) _invalid();
        walk(entry.key, depth + 1);
        walk(entry.value, depth + 1);
      }
    } else if (item is List) {
      if (item.length > 2000) _large();
      for (final child in item) {
        walk(child, depth + 1);
      }
    } else if (item is String) {
      textUnits += item.length;
      if (item.length > 16384 || textUnits > 2000000) _large();
    } else if (item is num) {
      if (!item.isFinite) _invalid();
    } else if (item != null && item is! bool) {
      _invalid();
    }
  }

  walk(value, 0);
}

Map<String, dynamic> musicObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _invalid();
  return Map<String, dynamic>.from(value);
}

String _text(Object? value, {int limit = 512, bool empty = false}) {
  if (value is! String ||
      value.length > limit ||
      (!empty && value.isEmpty) ||
      value.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
    _invalid();
  }
  return value;
}

String? _optionalText(Object? value) => value == null ? null : _text(value);
int _int(Object? value, {int max = 1000000}) {
  if (value is! int || value < 0 || value > max) _invalid();
  return value;
}

bool _bool(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

MusicMediaType _type(Object? value) =>
    MusicMediaType.values.where((t) => t.name == value).firstOrNull ??
    _invalid();

List<MusicAssistantEntry> parseMusicEntries(Object? raw) {
  validateMusicPayload(raw);
  if (raw is! List || raw.length > 100) _invalid();
  final ids = <String>{};
  return List.unmodifiable(
    raw.map((item) {
      final row = musicObject(item);
      if (row['domain'] != 'music_assistant') _invalid();
      final id = _text(row['entry_id'], limit: 128);
      if (!ids.add(id)) _invalid();
      if (!row.containsKey('disabled_by')) _invalid();
      final disabled = row['disabled_by'];
      if (disabled != null) _text(disabled, limit: 64);
      return MusicAssistantEntry(
        id: id,
        title: _text(row['title']),
        state: _text(row['state'], limit: 64),
        disabled: disabled != null,
      );
    }),
  );
}

MusicMediaItem _item(Object? raw, {MusicMediaType? expected, int depth = 0}) {
  if (depth > 2) _invalid();
  final row = musicObject(raw);
  final type = _type(row['media_type']);
  if (expected != null && expected != type) _invalid();
  final favorite = row['favorite'], explicit = row['explicit'];
  if (favorite != null && favorite is! bool ||
      explicit != null && explicit is! bool) {
    _invalid();
  }
  final artists = row['artists'];
  if (artists != null && (artists is! List || artists.length > 100)) _invalid();
  final album = row['album'];
  return MusicMediaItem(
    type: type,
    reference: MusicMediaReference(_text(row['uri'], limit: 4096)),
    name: _text(row['name']),
    version: _text(row['version'], empty: true),
    favorite: favorite as bool?,
    explicit: explicit as bool?,
    artists: [
      for (final artist in artists as List? ?? const [])
        _item(artist, expected: MusicMediaType.artist, depth: depth + 1).name,
    ],
    album: album == null
        ? null
        : _item(album, expected: MusicMediaType.album, depth: depth + 1).name,
  );
}

MusicLibraryPage parseMusicLibrary(Object? raw, MusicLibraryQuery query) {
  validateMusicPayload(raw);
  final row = musicObject(raw), items = row['items'];
  if (_type(row['media_type']) != query.type ||
      row['limit'] != query.limit ||
      row['offset'] != query.offset ||
      items is! List ||
      items.length > query.limit) {
    _invalid();
  }
  _text(row['order_by'], limit: 64);
  return MusicLibraryPage(
    items: [for (final item in items) _item(item, expected: query.type)],
    type: query.type,
    limit: query.limit,
    offset: query.offset,
  );
}

const _searchKeys = <MusicMediaType, String>{
  MusicMediaType.artist: 'artists',
  MusicMediaType.album: 'albums',
  MusicMediaType.track: 'tracks',
  MusicMediaType.playlist: 'playlists',
  MusicMediaType.radio: 'radio',
  MusicMediaType.audiobook: 'audiobooks',
  MusicMediaType.podcast: 'podcasts',
};
MusicSearchResults parseMusicSearch(Object? raw, MusicSearchQuery query) {
  validateMusicPayload(raw);
  final row = musicObject(raw);
  return MusicSearchResults({
    for (final entry in _searchKeys.entries)
      entry.key: () {
        final items = row[entry.value];
        if (items is! List || items.length > query.limit) _invalid();
        if (query.types.isNotEmpty &&
            !query.types.contains(entry.key) &&
            items.isNotEmpty) {
          _invalid();
        }
        return [for (final item in items) _item(item, expected: entry.key)];
      }(),
  });
}

MusicQueueItem? _queueItem(Object? raw) {
  if (raw == null) return null;
  final row = musicObject(raw);
  return MusicQueueItem(
    id: _text(row['queue_item_id'], limit: 256),
    name: _text(row['name']),
    durationSeconds: row['duration'] == null
        ? null
        : _int(row['duration'], max: 31536000),
    media: row['media_item'] == null ? null : _item(row['media_item']),
    streamTitle: _optionalText(row['stream_title']),
  );
}

MusicQueueSummary parseMusicQueue(Object? raw, String entityId) {
  validateMusicPayload(raw);
  final envelope = musicObject(raw);
  // Entity services return a map keyed by the exact requested entity identity.
  if (envelope.length != 1 || !envelope.containsKey(entityId)) _invalid();
  final row = musicObject(envelope[entityId]);
  if (!const [
    'queue_id',
    'name',
    'active',
    'items',
    'shuffle_enabled',
    'repeat_mode',
    'current_index',
    'elapsed_time',
    'current_item',
    'next_item',
  ].every(row.containsKey)) {
    _invalid();
  }
  final count = _int(row['items']);
  final index = row['current_index'] == null
      ? null
      : _int(row['current_index']);
  if (index != null && index >= count) _invalid();
  final repeat = _text(row['repeat_mode'], limit: 64);
  return MusicQueueSummary(
    id: _text(row['queue_id'], limit: 256),
    name: _text(row['name']),
    active: _bool(row['active']),
    itemCount: count,
    currentIndex: index,
    shuffleEnabled: _bool(row['shuffle_enabled']),
    repeatMode:
        MusicRepeatMode.values.where((m) => m.name == repeat).firstOrNull ??
        MusicRepeatMode.unknown,
    elapsedSeconds: _int(row['elapsed_time'], max: 31536000),
    current: _queueItem(row['current_item']),
    next: _queueItem(row['next_item']),
  );
}
