import '../../ha_playback/domain/ha_media_inventory.dart';

/// Read-only native music models. None contain artwork/stream URLs, provider
/// cookies, or a Music Assistant token. Catalog references are opaque handles.
enum MusicMediaType {
  artist,
  album,
  track,
  playlist,
  radio,
  audiobook,
  podcast,
}

enum MusicFailure {
  notConfigured,
  authentication,
  permission,
  transport,
  timeout,
  invalidResponse,
  unavailable,
  unsupported,
  stale,
  invalidSelection,
  tooLarge,
}

enum MusicDiscoverySource { inventory, configEntries, registry, services }

enum MusicReadService { search, getLibrary, getQueue }

class MusicException implements Exception {
  const MusicException(this.failure);
  final MusicFailure failure;
  @override
  String toString() => 'Music data could not be read';
}

class MusicRead<T> {
  const MusicRead({
    this.value,
    this.readAt,
    this.failure,
    this.isLoading = false,
    this.isPaused = false,
  });
  final T? value;
  final DateTime? readAt;
  final MusicFailure? failure;
  final bool isLoading, isPaused;
  bool isStaleAt(
    DateTime now, {
    Duration freshness = const Duration(minutes: 2),
  }) =>
      value != null &&
      (failure != null ||
          isPaused ||
          readAt == null ||
          now.isBefore(readAt!) ||
          now.difference(readAt!) > freshness);
}

class MusicAssistantEntry {
  const MusicAssistantEntry({
    required this.id,
    required this.title,
    required this.state,
    required this.disabled,
  });
  final String id, title, state;
  final bool disabled;
  bool get isLoaded => state == 'loaded' && !disabled;
}

class MusicQueueTarget {
  const MusicQueueTarget({
    required this.entityId,
    required this.configEntryId,
    required this.name,
    required this.available,
    required this.enabled,
    this.registryId,
    this.deviceId,
  });
  final String? registryId, deviceId;
  final String entityId, configEntryId, name;
  final bool available, enabled;
}

class MusicDiscovery {
  MusicDiscovery({
    required this.accountGeneration,
    required this.readAt,
    this.configured = true,
    this.inventory,
    List<MusicAssistantEntry> entries = const [],
    List<MusicQueueTarget> queueTargets = const [],
    Set<MusicReadService> services = const {},
    Map<MusicDiscoverySource, MusicFailure> issues = const {},
  }) : entries = List.unmodifiable(entries),
       queueTargets = List.unmodifiable(queueTargets),
       services = Set.unmodifiable(services),
       issues = Map.unmodifiable(issues);
  final Object accountGeneration;
  final DateTime readAt;
  final bool configured;
  final HaMediaInventory? inventory;
  final List<MusicAssistantEntry> entries;
  final List<MusicQueueTarget> queueTargets;
  final Set<MusicReadService> services;
  final Map<MusicDiscoverySource, MusicFailure> issues;

  /// Absence is evidence only after a successful config-entry discovery.
  bool get assistantNotInstalled =>
      configured &&
      entries.isEmpty &&
      !issues.containsKey(MusicDiscoverySource.configEntries);
  bool freshAt(DateTime now) =>
      !now.isBefore(readAt) &&
      now.difference(readAt) <= const Duration(minutes: 2);
}

/// Preserve the server's catalog identifier for a future explicit playback
/// command, without making it a display string or an image/network URL.
class MusicMediaReference {
  const MusicMediaReference(this.requestValue);
  final String requestValue;
  @override
  String toString() => 'Music catalog reference';
}

class MusicMediaItem {
  MusicMediaItem({
    required this.type,
    required this.reference,
    required this.name,
    required this.version,
    List<String> artists = const [],
    this.album,
    this.favorite,
    this.explicit,
  }) : artists = List.unmodifiable(artists);
  final MusicMediaType type;
  final MusicMediaReference reference;
  final String name, version;
  final List<String> artists;
  final String? album;
  final bool? favorite, explicit;
}

class MusicLibraryPage {
  MusicLibraryPage({
    required List<MusicMediaItem> items,
    required this.type,
    required this.offset,
    required this.limit,
  }) : items = List.unmodifiable(items);
  final List<MusicMediaItem> items;
  final MusicMediaType type;
  final int offset, limit;

  /// The HA service does not return a total or an authoritative next-page flag.
  bool get mayHaveMore => items.length == limit;
}

class MusicSearchResults {
  MusicSearchResults(Map<MusicMediaType, List<MusicMediaItem>> groups)
    : groups = Map.unmodifiable({
        for (final entry in groups.entries)
          entry.key: List<MusicMediaItem>.unmodifiable(entry.value),
      });
  final Map<MusicMediaType, List<MusicMediaItem>> groups;
  List<MusicMediaItem> get items =>
      List.unmodifiable(groups.values.expand((items) => items));
}

class MusicQueueItem {
  const MusicQueueItem({
    required this.id,
    required this.name,
    this.durationSeconds,
    this.media,
    this.streamTitle,
  });
  final String id, name;
  final int? durationSeconds;
  final MusicMediaItem? media;
  final String? streamTitle;
}

enum MusicRepeatMode { off, one, all, unknown }

/// HA get_queue returns an overview and current/next items, not the complete
/// ordered queue. The UI must not offer arbitrary queue edits from this result.
class MusicQueueSummary {
  const MusicQueueSummary({
    required this.id,
    required this.name,
    required this.active,
    required this.itemCount,
    required this.shuffleEnabled,
    required this.repeatMode,
    required this.elapsedSeconds,
    this.currentIndex,
    this.current,
    this.next,
  });
  final String id, name;
  final bool active, shuffleEnabled;
  final int itemCount, elapsedSeconds;
  final int? currentIndex;
  final MusicRepeatMode repeatMode;
  final MusicQueueItem? current, next;
}

class MusicLibraryQuery {
  const MusicLibraryQuery({
    required this.accountGeneration,
    required this.configEntryId,
    required this.type,
    this.offset = 0,
    this.limit = 25,
    this.favorite,
  });
  final Object accountGeneration;
  final String configEntryId;
  final MusicMediaType type;
  final int offset, limit;
  final bool? favorite;
  @override
  bool operator ==(Object other) =>
      other is MusicLibraryQuery &&
      identical(accountGeneration, other.accountGeneration) &&
      configEntryId == other.configEntryId &&
      type == other.type &&
      offset == other.offset &&
      limit == other.limit &&
      favorite == other.favorite;
  @override
  int get hashCode => Object.hash(
    identityHashCode(accountGeneration),
    configEntryId,
    type,
    offset,
    limit,
    favorite,
  );
}

class MusicSearchQuery {
  MusicSearchQuery({
    required this.accountGeneration,
    required this.configEntryId,
    required this.text,
    Set<MusicMediaType> types = const {},
    this.limit = 10,
    this.libraryOnly = false,
  }) : types = Set.unmodifiable(types);
  final Object accountGeneration;
  final String configEntryId, text;
  final Set<MusicMediaType> types;
  final int limit;
  final bool libraryOnly;
  @override
  bool operator ==(Object other) =>
      other is MusicSearchQuery &&
      identical(accountGeneration, other.accountGeneration) &&
      configEntryId == other.configEntryId &&
      text == other.text &&
      limit == other.limit &&
      libraryOnly == other.libraryOnly &&
      types.length == other.types.length &&
      types.every(other.types.contains);
  @override
  int get hashCode => Object.hash(
    identityHashCode(accountGeneration),
    configEntryId,
    text,
    limit,
    libraryOnly,
    Object.hashAllUnordered(types),
  );
}

class MusicQueueQuery {
  const MusicQueueQuery({
    required this.accountGeneration,
    required this.configEntryId,
    required this.entityId,
  });
  final Object accountGeneration;
  final String configEntryId, entityId;
  @override
  bool operator ==(Object other) =>
      other is MusicQueueQuery &&
      identical(accountGeneration, other.accountGeneration) &&
      configEntryId == other.configEntryId &&
      entityId == other.entityId;
  @override
  int get hashCode =>
      Object.hash(identityHashCode(accountGeneration), configEntryId, entityId);
}
