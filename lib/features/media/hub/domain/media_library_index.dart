import '../../arr/data/models/arr_library_item.dart';
import '../../arr/data/models/arr_queue_item.dart';
import '../../jellyfin/data/models/jellyfin_item.dart';
import 'media_identity.dart';
import 'media_title.dart';
import 'media_read_result.dart';

/// What one service knows about a title. Kept separate per source so the
/// index can answer "playable?", "downloading?" and "monitored?"
/// independently.
class MediaLibraryEntry {
  const MediaLibraryEntry({
    required this.identity,
    this.jellyfinItemId,
    this.playedFraction,
    this.arrItemId,
    this.monitored,
    this.complete,
    this.downloadProgress,
  });

  final MediaIdentity identity;
  final String? jellyfinItemId;
  final double? playedFraction;
  final int? arrItemId;
  final bool? monitored;
  final bool? complete;
  final double? downloadProgress;

  MediaLibraryEntry mergedWith(MediaLibraryEntry other) => MediaLibraryEntry(
    identity: identity.mergedWith(other.identity),
    jellyfinItemId: jellyfinItemId ?? other.jellyfinItemId,
    playedFraction: playedFraction ?? other.playedFraction,
    arrItemId: arrItemId ?? other.arrItemId,
    monitored: monitored ?? other.monitored,
    complete: complete ?? other.complete,
    downloadProgress: downloadProgress ?? other.downloadProgress,
  );

  MediaAvailability get availability {
    if (jellyfinItemId != null) return MediaAvailability.inLibrary;
    if (downloadProgress != null) return MediaAvailability.downloading;
    if (complete == true) return MediaAvailability.inLibrary;
    if (arrItemId != null) return MediaAvailability.monitored;
    return MediaAvailability.notAvailable;
  }
}

/// A lookup table over everything the connected services already have,
/// built once per refresh so resolving a title costs a map lookup rather
/// than a network call per title.
///
/// Entries are stored under *every* id they know (see
/// [MediaIdentity.allKeys]), because services don't agree on which ids
/// they carry — Sonarr may know only a TVDB id while Jellyseerr knows
/// only TMDB, and those two still need to meet.
class MediaLibraryIndex {
  MediaLibraryIndex._(
    this._byKey,
    this._jellyfinById, {
    this.readIssues = const [],
    this.successfulReads = const {},
  });

  final List<MediaReadIssue> readIssues;
  final Set<MediaReadKey> successfulReads;

  final Map<String, MediaLibraryEntry> _byKey;
  final Map<String, JellyfinItem> _jellyfinById;
  JellyfinItem? jellyfinItem(String? id) => _jellyfinById[id];

  /// Already-fetched items for local-only search; this performs no I/O.
  Iterable<JellyfinItem> get jellyfinItems => _jellyfinById.values;

  static final empty = MediaLibraryIndex._(const {}, const {});

  bool get isEmpty => _byKey.isEmpty;

  MediaLibraryEntry? lookup(MediaIdentity identity) {
    for (final key in identity.allKeys) {
      final hit = _byKey[key];
      if (hit != null) return hit;
    }
    return null;
  }

  MediaAvailability availabilityOf(MediaIdentity identity) =>
      lookup(identity)?.availability ?? MediaAvailability.notAvailable;

  /// Fills in everything the index knows about [title] — playability,
  /// download progress, the *arr row id — leaving fields the caller
  /// already resolved untouched.
  MediaTitle enrich(MediaTitle title) {
    final entry = lookup(title.identity);
    if (entry == null) return title;
    return title.copyWith(
      identity: title.identity.mergedWith(entry.identity),
      availability: title.availability == MediaAvailability.requested
          // A pending request still outranks "not tracked", but anything
          // the index actually found beats a stale request record.
          ? (entry.availability == MediaAvailability.notAvailable
                ? MediaAvailability.requested
                : entry.availability)
          : entry.availability,
      jellyfinItemId: title.jellyfinItemId ?? entry.jellyfinItemId,
      playedFraction: title.playedFraction ?? entry.playedFraction,
      downloadProgress: entry.downloadProgress,
      arrItemId: entry.arrItemId,
      monitored: entry.monitored,
    );
  }

  static MediaLibraryIndex build({
    List<JellyfinItem> jellyfinItems = const [],
    List<ArrLibraryItem> sonarrLibrary = const [],
    List<ArrLibraryItem> radarrLibrary = const [],
    List<ArrQueueItem> queue = const [],
    Iterable<MediaReadIssue> readIssues = const [],
    Iterable<MediaReadKey> successfulReads = const [],
  }) {
    final byKey = <String, MediaLibraryEntry>{};

    void add(MediaLibraryEntry entry) {
      final keys = entry.identity.allKeys;
      if (keys.isEmpty) return;
      // Merge rather than overwrite, so a title present in both Jellyfin
      // and Radarr keeps its playable id *and* its monitored state.
      MediaLibraryEntry merged = entry;
      for (final key in keys) {
        final existing = byKey[key];
        if (existing != null) merged = merged.mergedWith(existing);
      }
      for (final key in merged.identity.allKeys) {
        byKey[key] = merged;
      }
    }

    for (final item in jellyfinItems) {
      if (item.type != 'Movie' && item.type != 'Series') continue;
      final kind = jellyfinKindOf(item);
      if (kind == null) continue;
      final identity = MediaIdentity(
        kind: kind,
        tmdbId: item.tmdbId,
        tvdbId: item.tvdbId,
        imdbId: item.imdbId,
      );
      if (identity.isEmpty) continue;
      add(
        MediaLibraryEntry(
          identity: identity,
          jellyfinItemId: item.id,
          playedFraction: item.playedFraction > 0 ? item.playedFraction : null,
        ),
      );
    }

    void addArr(List<ArrLibraryItem> items, MediaKind kind) {
      for (final item in items) {
        final identity = MediaIdentity(
          kind: kind,
          tmdbId: item.tmdbId,
          tvdbId: item.tvdbId,
          imdbId: item.imdbId,
        );
        if (identity.isEmpty) continue;
        add(
          MediaLibraryEntry(
            identity: identity,
            arrItemId: item.id,
            monitored: item.monitored,
            complete: item.isComplete,
          ),
        );
      }
    }

    addArr(sonarrLibrary, MediaKind.tv);
    addArr(radarrLibrary, MediaKind.movie);

    for (final item in queue) {
      // A queue record belongs to a series when it carries a seriesId,
      // otherwise it's a movie grab.
      final kind = item.seriesId != null ? MediaKind.tv : MediaKind.movie;
      final identity = MediaIdentity(
        kind: kind,
        tmdbId: item.tmdbId,
        tvdbId: item.tvdbId,
        imdbId: item.imdbId,
      );
      if (identity.isEmpty) continue;
      add(
        MediaLibraryEntry(
          identity: identity,
          arrItemId: item.seriesId ?? item.movieId,
          downloadProgress: item.progressFraction ?? 0,
        ),
      );
    }

    return MediaLibraryIndex._(
      byKey,
      {for (final item in jellyfinItems) item.id: item},
      readIssues: orderedMediaIssues(readIssues),
      successfulReads: Set.unmodifiable(successfulReads),
    );
  }
}

/// Maps a Jellyfin item type onto a hub media kind. Episodes resolve to
/// their series, since the hub is title-centric; anything else (audio,
/// books, folders) isn't part of this hub.
MediaKind? jellyfinKindOf(JellyfinItem item) => switch (item.type) {
  'Movie' => MediaKind.movie,
  'Series' || 'Season' || 'Episode' => MediaKind.tv,
  _ => null,
};
