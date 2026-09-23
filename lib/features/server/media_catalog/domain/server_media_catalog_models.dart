Never _invalid() => throw const FormatException('invalid_response');

enum ServerMediaCatalogKind {
  movie('movie'),
  episode('episode');

  const ServerMediaCatalogKind(this.wire);
  final String wire;
}

final _mediaKey = RegExp(
  r'^(?:movie:tmdb:[1-9][0-9]{0,11}|episode:tvdb:[1-9][0-9]{0,11}:[0-9]{1,4}:[0-9]{1,5})$',
);
final _unsafeText = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]',
);

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7ffffffffffffffe) _invalid();
  return value;
}

String _identity(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _text(Object? value, {required int maximum}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      value != value.trim() ||
      _unsafeText.hasMatch(value)) {
    _invalid();
  }
  return value;
}

final class ServerMediaCatalogItem {
  const ServerMediaCatalogItem._({
    required this.itemId,
    required this.mediaKey,
    required this.title,
    required this.kind,
    required this.runtimeSeconds,
  });

  factory ServerMediaCatalogItem.fromJson(Object? value) {
    final map = _object(value, {
      'itemId',
      'mediaKey',
      'title',
      'mediaKind',
      'runtimeSeconds',
    });
    final mediaKey = map['mediaKey'];
    final kind = switch (map['mediaKind']) {
      'movie' => ServerMediaCatalogKind.movie,
      'episode' => ServerMediaCatalogKind.episode,
      _ => _invalid(),
    };
    final runtime = map['runtimeSeconds'];
    if (mediaKey is! String ||
        !_mediaKey.hasMatch(mediaKey) ||
        (kind == ServerMediaCatalogKind.movie) !=
            mediaKey.startsWith('movie:') ||
        runtime != null &&
            (runtime is! int || runtime < 1 || runtime > 604800)) {
      _invalid();
    }
    return ServerMediaCatalogItem._(
      itemId: _identity(map['itemId']),
      mediaKey: mediaKey,
      title: _text(map['title'], maximum: 240),
      kind: kind,
      runtimeSeconds: runtime as int?,
    );
  }

  final String itemId, mediaKey, title;
  final ServerMediaCatalogKind kind;
  final int? runtimeSeconds;
}

final class ServerMediaCatalogPage {
  const ServerMediaCatalogPage._({
    required this.query,
    required this.mediaKind,
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
    required this.offset,
    required this.nextOffset,
    required this.total,
    required this.items,
  });

  factory ServerMediaCatalogPage.fromJson(
    Object? value, {
    required String query,
    required ServerMediaCatalogKind? mediaKind,
  }) {
    final map = _object(value, {
      'schemaVersion',
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'jellyfinServiceRevision',
      'offset',
      'nextOffset',
      'total',
      'items',
    });
    final offset = map['offset'];
    final next = map['nextOffset'];
    final total = map['total'];
    final rawItems = map['items'];
    if (map['schemaVersion'] != 1 ||
        offset is! int ||
        offset < 0 ||
        offset > 4096 ||
        total is! int ||
        total < 0 ||
        total > 4096 ||
        next != null && (next is! int || next < 1 || next > 4096) ||
        rawItems is! List ||
        rawItems.length > 50) {
      _invalid();
    }
    final items = rawItems
        .map(ServerMediaCatalogItem.fromJson)
        .toList(growable: false);
    final end = offset + items.length;
    if (offset > total ||
        (next == null && end != total) ||
        (next != null && (next != end || next >= total)) ||
        items.map((item) => item.itemId).toSet().length != items.length) {
      _invalid();
    }
    return ServerMediaCatalogPage._(
      query: query,
      mediaKind: mediaKind,
      installationId: _identity(map['installationId']),
      installationRevision: _revision(map['installationRevision']),
      snapshotRevision: _revision(map['snapshotRevision']),
      jellyfinServiceRevision: _revision(map['jellyfinServiceRevision']),
      offset: offset,
      nextOffset: next as int?,
      total: total,
      items: List.unmodifiable(items),
    );
  }

  final String installationId;
  final String query;
  final ServerMediaCatalogKind? mediaKind;
  final int installationRevision, snapshotRevision, jellyfinServiceRevision;
  final int offset, total;
  final int? nextOffset;
  final List<ServerMediaCatalogItem> items;
}
