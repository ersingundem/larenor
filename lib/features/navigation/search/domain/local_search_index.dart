import '../../../dashboard/domain/dashboard_room.dart';
import '../../../media/hub/domain/media_title.dart';
import '../../../settings/data/app_service.dart';
import 'navigation_target.dart';

/// A forgiving search key for Turkish/English names. Dotted and dotless I
/// share a key; accents and decomposed combining marks do not block a match.
String foldSearchText(String value) {
  const replacements = {
    'ı': 'i',
    'İ': 'i',
    'ç': 'c',
    'ğ': 'g',
    'ö': 'o',
    'ş': 's',
    'ü': 'u',
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'ā': 'a',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ē': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ī': 'i',
    'ñ': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ø': 'o',
    'ō': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ū': 'u',
    'ý': 'y',
    'ÿ': 'y',
    'ß': 'ss',
  };
  final out = StringBuffer();
  for (final rune in value.replaceAll('İ', 'i').toLowerCase().runes) {
    if (rune >= 0x0300 && rune <= 0x036f) continue;
    final char = String.fromCharCode(rune);
    out.write(replacements[char] ?? char);
  }
  return out.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

enum LocalSearchKind { room, entity, scene, script, media, system, page }

class LocalSearchEntity {
  const LocalSearchEntity({required this.entityId, required this.name});
  final String entityId;
  final String name;
  String get domain => entityId.split('.').first;
}

class LocalSearchItem {
  const LocalSearchItem({
    required this.id,
    required this.title,
    required this.kind,
    required this.target,
    this.roomNames = const [],
    this.detail,
  });
  final String id;
  final String title;
  final LocalSearchKind kind;
  final NavigationTarget target;
  final List<String> roomNames;
  final String? detail;
}

class _Document {
  _Document(this.item, Iterable<String> primary, Iterable<String> context)
    : primary = primary.map(foldSearchText).where((s) => s.isNotEmpty).toSet(),
      context = context.map(foldSearchText).where((s) => s.isNotEmpty).toSet(),
      titleKey = foldSearchText(item.title);
  final LocalSearchItem item;
  final Set<String> primary;
  final Set<String> context;
  final String titleKey;

  int? match(String query, List<String> terms) {
    if (primary.contains(query)) return 0;
    if (primary.any((value) => value.startsWith(query))) return 1;
    if (primary.any((value) => value.contains(query))) return 2;
    if (context.contains(query)) return 3;
    if (context.any((value) => value.startsWith(query))) return 4;
    if (terms.every(
      (term) =>
          primary.any((value) => value.contains(term)) ||
          context.any((value) => value.contains(term)),
    )) {
      return 5;
    }
    return null;
  }
}

/// Normalized once per metadata snapshot, then searched without networking or
/// executing actions. Entity state-only changes do not require a new index.
class LocalSearchIndex {
  LocalSearchIndex._(this._documents);
  static final empty = LocalSearchIndex._(const []);
  final List<_Document> _documents;
  int get length => _documents.length;
  bool get isEmpty => _documents.isEmpty;

  factory LocalSearchIndex.build({
    Iterable<DashboardRoom> rooms = const [],
    Iterable<LocalSearchEntity> entities = const [],
    Iterable<MediaTitle> media = const [],
    Iterable<AppService> services = const [],
    Iterable<HomePageTarget> pages = const [],
  }) {
    final documents = <String, _Document>{};
    for (final page in pages.toSet()) {
      final aliases = switch (page) {
        HomePageTarget.today => [
          'Today',
          'Bugün',
          'takvim',
          'calendar',
          'alışveriş',
          'shopping',
          'ev işleri',
          'görevler',
          'tasks',
          'bildirimler',
          'notifications',
        ],
        HomePageTarget.energy => [
          'Energy',
          'Enerji',
          'bakım',
          'maintenance',
          'tüketim',
          'consumption',
          'pil',
          'battery',
          'capacity',
          'kapasite',
        ],
        HomePageTarget.intercom => [
          'Intercom',
          'Diafon',
          'kapı',
          'door',
          'zil',
          'doorbell',
          'Netelsan',
          'Algan',
        ],
      };
      final item = LocalSearchItem(
        id: 'page:${page.name}',
        title: aliases.first,
        kind: LocalSearchKind.page,
        target: HomePageNavigationTarget(page),
      );
      documents[item.id] = _Document(item, aliases, const []);
    }
    final memberships = <String, Set<String>>{};
    for (final room in rooms) {
      final item = LocalSearchItem(
        id: 'room:${room.id}',
        title: room.name,
        kind: LocalSearchKind.room,
        target: RoomNavigationTarget(room.id),
      );
      documents[item.id] = _Document(
        item,
        [room.name, room.id],
        ['room', 'oda'],
      );
      for (final id in room.entityIds) {
        memberships.putIfAbsent(id, () => {}).add(room.name);
      }
    }
    for (final entity in entities) {
      final names = (memberships[entity.entityId] ?? {}).toList()..sort();
      final kind = switch (entity.domain) {
        'scene' => LocalSearchKind.scene,
        'script' => LocalSearchKind.script,
        _ => LocalSearchKind.entity,
      };
      final item = LocalSearchItem(
        id: 'entity:${entity.entityId}',
        title: entity.name,
        kind: kind,
        target: EntityNavigationTarget(entity.entityId),
        roomNames: List.unmodifiable(names),
        detail: entity.entityId,
      );
      documents[item.id] = _Document(
        item,
        [entity.name, entity.entityId],
        [...names, entity.domain, ..._domainAliases[entity.domain] ?? const []],
      );
    }

    for (final document in _mediaDocuments(media)) {
      documents[document.item.id] = document;
    }
    for (final service in services.toSet()) {
      final name = serviceDisplayName(service);
      final item = LocalSearchItem(
        id: 'system:${service.name}',
        title: name,
        kind: LocalSearchKind.system,
        target: SystemNavigationTarget(service),
      );
      documents[item.id] = _Document(
        item,
        [name, service.name],
        [
          'system',
          'sistem',
          'service',
          'servis',
          ...switch (service) {
            AppService.keenetic => [
              'network',
              'router',
              'internet',
              'ağ',
              'yönlendirici',
            ],
            AppService.proxmox => [
              'server',
              'sunucu',
              'virtual machine',
              'sanal makine',
            ],
            _ => ['media', 'medya'],
          },
        ],
      );
    }
    return LocalSearchIndex._(List.unmodifiable(documents.values));
  }

  List<LocalSearchItem> search(String query) {
    final folded = foldSearchText(query);
    if (folded.isEmpty) return const [];
    final terms = folded.split(' ');
    final matches = <({int rank, _Document document})>[];
    for (final document in _documents) {
      final rank = document.match(folded, terms);
      if (rank != null) matches.add((rank: rank, document: document));
    }
    matches.sort((a, b) {
      var order = a.rank.compareTo(b.rank);
      if (order != 0) return order;
      order = a.document.titleKey.compareTo(b.document.titleKey);
      if (order != 0) return order;
      return a.document.item.id.compareTo(b.document.item.id);
    });
    return [for (final match in matches) match.document.item];
  }
}

/// Join all known aliases before emitting rows. A later title can bridge an
/// IMDb-only and TMDB-only record; neither source order nor duplicate rows may
/// alter the result's identifier. The alias map avoids pairwise catalog scans.
Iterable<_Document> _mediaDocuments(Iterable<MediaTitle> media) sync* {
  final records = <({MediaTitle title, Set<String> keys})>[];
  final parents = <int>[];
  final ownerByAlias = <String, int>{};
  int root(int index) {
    while (parents[index] != index) {
      parents[index] = parents[parents[index]];
      index = parents[index];
    }
    return index;
  }

  for (final title in media) {
    final kind = title.identity.kind.name;
    final keys = {
      ...title.identity.allKeys,
      if (title.jellyfinSeriesId != null)
        '$kind:jellyfin:${title.jellyfinSeriesId}',
      if (title.jellyfinItemId != null)
        '$kind:jellyfin:${title.jellyfinItemId}',
      if (title.jellyfinLookupId != null)
        '$kind:jellyfin:${title.jellyfinLookupId}',
    };
    if (keys.isEmpty) continue;
    final index = records.length;
    records.add((title: title, keys: keys));
    parents.add(index);
    for (final key in keys) {
      final previous = ownerByAlias[key];
      if (previous != null) parents[root(previous)] = root(index);
      ownerByAlias[key] = index;
    }
  }
  final groups = <int, List<int>>{};
  for (var i = 0; i < records.length; i++) {
    groups.putIfAbsent(root(i), () => []).add(i);
  }
  for (final group in groups.values) {
    group.sort((a, b) {
      final left = records[a].title;
      final right = records[b].title;
      // Prefer a playable, informative cached snapshot deterministically.
      var order = left.availability.index.compareTo(right.availability.index);
      if (order != 0) return order;
      order = records[b].keys.length.compareTo(records[a].keys.length);
      if (order != 0) return order;
      order = foldSearchText(left.title).compareTo(foldSearchText(right.title));
      if (order != 0) return order;
      return MediaNavigationTarget.fromTitle(left).location
          .compareTo(MediaNavigationTarget.fromTitle(right).location);
    });
    var title = records[group.first].title;
    final keys = <String>{};
    final names = <String>{};
    for (final i in group) {
      final other = records[i].title;
      keys.addAll(records[i].keys);
      names.add(other.title);
      title = title.copyWith(
        identity: title.identity.mergedWith(other.identity),
        year: title.year ?? other.year,
        jellyfinItemId: title.jellyfinItemId ?? other.jellyfinItemId,
        jellyfinLookupId: title.jellyfinLookupId ?? other.jellyfinLookupId,
        jellyfinSeriesId: title.jellyfinSeriesId ?? other.jellyfinSeriesId,
        overview: title.overview ?? other.overview,
        posterUrl: title.posterUrl ?? other.posterUrl,
        backdropUrl: title.backdropUrl ?? other.backdropUrl,
        arrItemId: title.arrItemId ?? other.arrItemId,
        monitored: title.monitored ?? other.monitored,
        playedFraction: title.playedFraction ?? other.playedFraction,
        downloadProgress: title.downloadProgress ?? other.downloadProgress,
        rating: title.rating ?? other.rating,
      );
    }
    final stableKey = !title.identity.isEmpty
        ? title.identity.key
        : '${title.identity.kind.name}:jellyfin:${title.jellyfinSeriesId ?? title.jellyfinItemId ?? title.jellyfinLookupId}';
    final item = LocalSearchItem(
      id: 'media:$stableKey',
      title: title.title,
      kind: LocalSearchKind.media,
      target: MediaNavigationTarget.fromTitle(title),
      detail: title.year == null ? null : '${title.year}',
    );
    yield _Document(item, names, [
      ...keys,
      if (title.year != null) '${title.year}',
      if (title.isTv) ...[
        'dizi',
        'tv',
        'series',
        'show',
      ] else ...[
        'film',
        'movie',
      ],
    ]);
  }
}

String serviceDisplayName(AppService service) => switch (service) {
  AppService.jellyfin => 'Jellyfin',
  AppService.jellyseerr => 'Jellyseerr',
  AppService.sonarr => 'Sonarr',
  AppService.radarr => 'Radarr',
  AppService.lidarr => 'Lidarr',
  AppService.readarr => 'Readarr',
  AppService.bazarr => 'Bazarr',
  AppService.prowlarr => 'Prowlarr',
  AppService.qbittorrent => 'qBittorrent',
  AppService.proxmox => 'Proxmox',
  AppService.keenetic => 'Keenetic',
};

const _domainAliases = <String, List<String>>{
  'light': ['light', 'lamp', 'ışık', 'lamba', 'aydınlatma'],
  'media_player': ['tv', 'television', 'televizyon', 'media', 'medya'],
  'scene': ['scene', 'sahne'],
  'script': ['script', 'betik'],
  'climate': ['climate', 'thermostat', 'iklim', 'termostat', 'ısıtma'],
  'cover': ['cover', 'blind', 'perde', 'panjur'],
  'lock': ['lock', 'door', 'kilit', 'kapı'],
  'switch': ['switch', 'anahtar', 'priz'],
  'sensor': ['sensor', 'sensör'],
  'binary_sensor': ['sensor', 'sensör'],
  'fan': ['fan', 'vantilatör'],
};
