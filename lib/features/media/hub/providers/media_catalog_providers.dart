import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../arr/data/models/arr_calendar_item.dart';
import '../../arr/data/models/arr_library_item.dart';
import '../../arr/data/models/arr_queue_item.dart';
import '../../arr/providers/radarr_providers.dart';
import '../../arr/providers/sonarr_providers.dart';
import '../../jellyfin/data/models/jellyfin_item.dart';
import '../../jellyfin/providers/jellyfin_providers.dart';
import '../../jellyseerr/data/models/jellyseerr_result.dart';
import '../../jellyseerr/providers/jellyseerr_providers.dart';
import '../domain/media_identity.dart';
import '../domain/media_library_index.dart';
import '../domain/media_title.dart';

part 'media_catalog_providers.g.dart';

/// Runs [task] and swallows any failure into [fallback].
///
/// The hub deliberately degrades rather than fails: one unreachable
/// service (a Sonarr box that's off, an expired Jellyseerr key) should
/// cost you that one row, not the whole screen.
Future<T> _orEmpty<T>(Future<T> Function() task, T fallback) async {
  try {
    return await task();
  } catch (_) {
    return fallback;
  }
}

/// Everything the connected services already have, indexed for O(1)
/// availability lookups. Rebuilt when any underlying connection changes.
@riverpod
Future<MediaLibraryIndex> mediaLibraryIndex(Ref ref) async {
  final jellyfin = ref.watch(jellyfinClientProvider);
  final sonarr = ref.watch(sonarrClientProvider);
  final radarr = ref.watch(radarrClientProvider);

  final results = await Future.wait([
    _orEmpty<List<JellyfinItem>>(
      () => jellyfin?.getAllMoviesAndSeries() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<ArrLibraryItem>>(
      () => sonarr?.getLibrary() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<ArrLibraryItem>>(
      () => radarr?.getLibrary() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<ArrQueueItem>>(
      () => sonarr?.getQueue() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<ArrQueueItem>>(
      () => radarr?.getQueue() ?? Future.value(const []),
      const [],
    ),
  ]);

  return MediaLibraryIndex.build(
    jellyfinItems: results[0] as List<JellyfinItem>,
    sonarrLibrary: results[1] as List<ArrLibraryItem>,
    radarrLibrary: results[2] as List<ArrLibraryItem>,
    queue: [
      ...results[3] as List<ArrQueueItem>,
      ...results[4] as List<ArrQueueItem>,
    ],
  );
}

/// Converts a Jellyfin item into a hub title. Episodes are folded up to
/// their series so a row never shows the same show twice.
MediaTitle? mediaTitleFromJellyfin(
  JellyfinItem item, {
  required String? Function(String itemId, {String type, String? tag}) imageUrl,
}) {
  final kind = jellyfinKindOf(item);
  if (kind == null) return null;

  final identity = MediaIdentity(
    kind: kind,
    tmdbId: item.tmdbId,
    tvdbId: item.tvdbId,
    imdbId: item.imdbId,
  );

  return MediaTitle(
    identity: identity,
    title: item.seriesName ?? item.name,
    availability: MediaAvailability.inLibrary,
    year: item.productionYear,
    overview: item.overview,
    posterUrl: imageUrl(item.id, tag: item.imageTags?['Primary']),
    backdropUrl: item.backdropImageTags?.isNotEmpty ?? false
        ? imageUrl(
            item.id,
            type: 'Backdrop',
            tag: item.backdropImageTags!.first,
          )
        : null,
    jellyfinItemId: item.id,
    playedFraction: item.playedFraction > 0 ? item.playedFraction : null,
    rating: item.communityRating,
  );
}

MediaTitle mediaTitleFromJellyseerr(
  JellyseerrResult result, {
  required String? Function(String?) posterUrl,
  required String? Function(String?) backdropUrl,
}) {
  final identity = MediaIdentity(
    kind: result.isTv ? MediaKind.tv : MediaKind.movie,
    tmdbId: result.tmdbId,
    tvdbId: result.mediaInfo?.tvdbId,
  );

  // Jellyseerr's own view of a title only tells us whether it's been
  // requested — whether it's actually playable is the library index's
  // call, applied later by `enrich`.
  final availability = switch (result.status) {
    JellyseerrMediaStatus.pending ||
    JellyseerrMediaStatus.processing => MediaAvailability.requested,
    JellyseerrMediaStatus.available ||
    JellyseerrMediaStatus.partiallyAvailable => MediaAvailability.inLibrary,
    JellyseerrMediaStatus.unknown => MediaAvailability.notAvailable,
  };

  return MediaTitle(
    identity: identity,
    title: result.displayTitle,
    availability: availability,
    year: result.year,
    overview: result.overview,
    posterUrl: posterUrl(result.posterPath),
    backdropUrl: backdropUrl(result.backdropPath),
    jellyfinItemId: result.mediaInfo?.jellyfinMediaId,
    rating: result.voteAverage,
  );
}

MediaTitle? mediaTitleFromCalendar(ArrCalendarItem item, MediaKind kind) {
  final identity = MediaIdentity(
    kind: kind,
    tmdbId: item.tmdbId,
    tvdbId: item.tvdbId,
    imdbId: item.imdbId,
  );
  if (identity.isEmpty) return null;

  return MediaTitle(
    identity: identity,
    title: item.title,
    availability: item.hasFile
        ? MediaAvailability.inLibrary
        : MediaAvailability.monitored,
    posterUrl: item.posterUrl,
  );
}

/// Drops repeats of the same title, keeping the first occurrence — used
/// so a row built from two services doesn't show one film twice.
List<MediaTitle> dedupeTitles(Iterable<MediaTitle> titles) {
  final seen = <String>{};
  final out = <MediaTitle>[];
  for (final title in titles) {
    final keys = title.identity.allKeys;
    // Titles with no external ids can't be deduped, so they're kept
    // as-is rather than collapsed onto each other.
    if (keys.isEmpty) {
      out.add(title);
      continue;
    }
    if (keys.any(seen.contains)) continue;
    seen.addAll(keys);
    out.add(title);
  }
  return out;
}

/// One horizontal row on the hub.
class MediaRowData {
  const MediaRowData({required this.id, required this.titles});

  final MediaRowId id;
  final List<MediaTitle> titles;
}

enum MediaRowId {
  continueWatching,
  recentlyAdded,
  trending,
  comingSoon,
  downloading,
}

@riverpod
Future<List<MediaRowData>> mediaHubRows(Ref ref) async {
  final index = await ref.watch(mediaLibraryIndexProvider.future);
  final jellyfin = ref.watch(jellyfinClientProvider);
  final jellyseerr = ref.watch(jellyseerrClientProvider);
  final sonarr = ref.watch(sonarrClientProvider);
  final radarr = ref.watch(radarrClientProvider);

  String? jfImage(String id, {String type = 'Primary', String? tag}) =>
      jellyfin?.imageUrl(id, type: type, tag: tag);

  final results = await Future.wait([
    _orEmpty<List<JellyfinItem>>(
      () => jellyfin?.getResumeItems() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<JellyfinItem>>(
      () => jellyfin?.getLatestItems() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<JellyseerrResult>>(
      () => jellyseerr?.discoverTrending() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<ArrCalendarItem>>(
      () => sonarr?.getCalendar() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<ArrCalendarItem>>(
      () => radarr?.getCalendar() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<ArrQueueItem>>(
      () => sonarr?.getQueue() ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<ArrQueueItem>>(
      () => radarr?.getQueue() ?? Future.value(const []),
      const [],
    ),
  ]);

  List<MediaTitle> fromJellyfin(List<JellyfinItem> items) => dedupeTitles(
    items
        .map((e) => mediaTitleFromJellyfin(e, imageUrl: jfImage))
        .whereType<MediaTitle>()
        .map(index.enrich),
  );

  final comingSoon = dedupeTitles(
    [
      ...(results[3] as List<ArrCalendarItem>)
          .map((e) => mediaTitleFromCalendar(e, MediaKind.tv))
          .whereType<MediaTitle>(),
      ...(results[4] as List<ArrCalendarItem>)
          .map((e) => mediaTitleFromCalendar(e, MediaKind.movie))
          .whereType<MediaTitle>(),
    ].map(index.enrich),
  );

  final downloading = dedupeTitles(
    [...results[5] as List<ArrQueueItem>, ...results[6] as List<ArrQueueItem>]
        .map((item) {
          final kind = item.seriesId != null ? MediaKind.tv : MediaKind.movie;
          return MediaTitle(
            identity: MediaIdentity(
              kind: kind,
              tmdbId: item.tmdbId,
              tvdbId: item.tvdbId,
              imdbId: item.imdbId,
            ),
            title: item.title,
            availability: MediaAvailability.downloading,
            downloadProgress: item.progressFraction,
          );
        })
        .map(index.enrich),
  );

  final rows = <MediaRowData>[
    MediaRowData(
      id: MediaRowId.continueWatching,
      titles: fromJellyfin(results[0] as List<JellyfinItem>),
    ),
    MediaRowData(
      id: MediaRowId.recentlyAdded,
      titles: fromJellyfin(results[1] as List<JellyfinItem>),
    ),
    MediaRowData(
      id: MediaRowId.trending,
      titles: dedupeTitles(
        (results[2] as List<JellyseerrResult>)
            .map(
              (e) => mediaTitleFromJellyseerr(
                e,
                posterUrl: (p) => jellyseerr?.posterUrl(p),
                backdropUrl: (p) => jellyseerr?.backdropUrl(p),
              ),
            )
            .map(index.enrich),
      ),
    ),
    MediaRowData(id: MediaRowId.comingSoon, titles: comingSoon),
    MediaRowData(id: MediaRowId.downloading, titles: downloading),
  ];

  return rows.where((row) => row.titles.isNotEmpty).toList();
}

/// Unified search: the library and the requestable catalogue at once,
/// merged so one title is one result no matter how many services know it.
@riverpod
Future<List<MediaTitle>> mediaSearch(Ref ref, String query) async {
  if (query.trim().isEmpty) return const [];

  final index = await ref.watch(mediaLibraryIndexProvider.future);
  final jellyfin = ref.watch(jellyfinClientProvider);
  final jellyseerr = ref.watch(jellyseerrClientProvider);

  final results = await Future.wait([
    _orEmpty<List<JellyfinItem>>(
      () => jellyfin?.search(query) ?? Future.value(const []),
      const [],
    ),
    _orEmpty<List<JellyseerrResult>>(
      () => jellyseerr?.search(query) ?? Future.value(const []),
      const [],
    ),
  ]);

  // Library hits lead: something already playable is almost always what
  // the user meant, and deduping keeps the first occurrence.
  return dedupeTitles(
    [
      ...(results[0] as List<JellyfinItem>)
          .map(
            (e) => mediaTitleFromJellyfin(
              e,
              imageUrl: (id, {String type = 'Primary', String? tag}) =>
                  jellyfin?.imageUrl(id, type: type, tag: tag),
            ),
          )
          .whereType<MediaTitle>(),
      ...(results[1] as List<JellyseerrResult>).map(
        (e) => mediaTitleFromJellyseerr(
          e,
          posterUrl: (p) => jellyseerr?.posterUrl(p),
          backdropUrl: (p) => jellyseerr?.backdropUrl(p),
        ),
      ),
    ].map(index.enrich),
  );
}
