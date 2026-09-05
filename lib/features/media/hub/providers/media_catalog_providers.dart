import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../arr/data/models/arr_calendar_item.dart';
import '../../arr/data/models/arr_library_item.dart';
import '../../arr/data/models/arr_lookup_result.dart';
import '../../arr/data/models/arr_queue_item.dart';
import '../../arr/providers/radarr_providers.dart';
import '../../arr/providers/sonarr_providers.dart';
import '../../jellyfin/data/models/jellyfin_item.dart';
import '../../jellyfin/providers/jellyfin_providers.dart';
import '../../jellyseerr/data/models/jellyseerr_result.dart';
import '../../jellyseerr/data/models/jellyseerr_request_item.dart';
import '../../jellyseerr/providers/jellyseerr_providers.dart';
import '../../../health/data/health_monitor.dart';
import '../../../health/data/integration_health.dart';
import '../../data/media_api_exception.dart';
import '../domain/media_read_result.dart';
import '../domain/media_identity.dart';
import '../domain/media_library_index.dart';
import '../domain/media_title.dart';

part 'media_catalog_providers.g.dart';

/// A collector belongs to one async provider build. Failures are attached to
/// that result, never accumulated in a shared side channel across accounts.
class _MediaReads {
  final issues = <MediaReadIssue>[];
  final successful = <MediaReadKey>{};
  final _freshSuccessful = <MediaReadKey>{};
  final readTimes = <MediaReadKey, DateTime>{};

  Future<T> read<T>(
    MediaReadKey key,
    bool available,
    Future<T> Function() task,
    T fallback,
  ) async {
    if (!available) return fallback;
    try {
      final value = await task().timeout(const Duration(seconds: 20));
      successful.add(key);
      // Queue providers own their parsed-read timestamps: their Future may
      // already be cached, so consuming it cannot make that read fresh again.
      if (key.operation != MediaReadOperation.queue) {
        _freshSuccessful.add(key);
        readTimes[key] = DateTime.now();
      }
      return value;
    } catch (error) {
      issues.add(MediaReadIssue(key, _failureOf(error)));
      return fallback;
    }
  }

  void include(MediaLibraryIndex index) {
    issues.addAll(index.readIssues);
    successful.addAll(index.successfulReads);
  }

  /// Report complete parsed reads, then any partial failure. A successful
  /// sibling endpoint must not erase a failed library/calendar in this batch.
  void publish(Ref ref, Iterable<HealthSession?> sessions) {
    if (!ref.mounted) return;
    for (final session in sessions.whereType<HealthSession>()) {
      if (_freshSuccessful.any((read) => read.service == session.id)) {
        session.readSucceeded();
      }
      final failures =
          issues
              .where((issue) => issue.read.service == session.id)
              .map((issue) => issue.failure)
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      if (failures.isNotEmpty) session.failed(failures.first);
    }
  }
}

HealthFailure _failureOf(Object error) {
  if (error is TimeoutException) return HealthFailure.timeout;
  if (error is http.ClientException) return HealthFailure.transport;
  if (error is MediaApiException) {
    return switch (error.statusCode) {
      401 => HealthFailure.authentication,
      403 => HealthFailure.permission,
      final int status when status >= 500 => HealthFailure.server,
      _ => HealthFailure.invalidResponse,
    };
  }
  return HealthFailure.invalidResponse;
}

/// Everything the connected services already have, indexed for O(1)
/// availability lookups. Rebuilt when any underlying connection changes.
@riverpod
Future<MediaLibraryIndex> mediaLibraryIndex(Ref ref) async {
  final reads = _MediaReads();
  final jellyfin = ref.watch(jellyfinClientProvider);
  final jellyseerr = ref.watch(jellyseerrClientProvider);
  final sonarr = ref.watch(sonarrClientProvider);
  final radarr = ref.watch(radarrClientProvider);

  final results = await Future.wait([
    reads.read<List<JellyfinItem>>(
      const MediaReadKey(IntegrationId.jellyfin, MediaReadOperation.library),
      jellyfin != null,
      () => jellyfin?.getAllMoviesAndSeries() ?? Future.value(const []),
      const [],
    ),
    reads.read<List<ArrLibraryItem>>(
      const MediaReadKey(IntegrationId.sonarr, MediaReadOperation.library),
      sonarr != null,
      () => sonarr?.getLibrary() ?? Future.value(const []),
      const [],
    ),
    reads.read<List<ArrLibraryItem>>(
      const MediaReadKey(IntegrationId.radarr, MediaReadOperation.library),
      radarr != null,
      () => radarr?.getLibrary() ?? Future.value(const []),
      const [],
    ),
    reads.read<List<ArrQueueItem>>(
      const MediaReadKey(IntegrationId.sonarr, MediaReadOperation.queue),
      sonarr != null,
      () => ref.watch(sonarrQueueProvider.future),
      const [],
    ),
    reads.read<List<ArrQueueItem>>(
      const MediaReadKey(IntegrationId.radarr, MediaReadOperation.queue),
      radarr != null,
      () => ref.watch(radarrQueueProvider.future),
      const [],
    ),
    reads.read<List<JellyseerrRequestItem>>(
      const MediaReadKey(IntegrationId.jellyseerr, MediaReadOperation.requests),
      jellyseerr != null,
      () => jellyseerr!.myRequests(),
      const [],
    ),
  ]);

  reads.publish(ref, [
    jellyfin?.healthSession,
    sonarr?.healthSession,
    radarr?.healthSession,
    jellyseerr?.healthSession,
  ]);
  final libraryTimes =
      reads.readTimes.entries
          .where((entry) => entry.key.operation == MediaReadOperation.library)
          .map((entry) => entry.value)
          .toList()
        ..sort();
  return MediaLibraryIndex.build(
    readAt: libraryTimes.isEmpty ? null : libraryTimes.first,
    // This endpoint is a bounded recent-request view. Absence is not evidence
    // that no request exists; only matching records contribute status.
    requests: results[5] as List<JellyseerrRequestItem>,
    readIssues: reads.issues,
    successfulReads: reads.successful,
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
  JellyfinItem? series,
  required String? Function(String itemId, {String type, String? tag}) imageUrl,
}) {
  final kind = jellyfinKindOf(item);
  if (kind == null) return null;

  // Episode ProviderIds identify the episode itself, never its parent show.
  final metadata = item.type == 'Episode' || item.type == 'Season'
      ? series
      : item;
  final identity = MediaIdentity(
    kind: kind,
    tmdbId: metadata?.tmdbId,
    tvdbId: metadata?.tvdbId,
    imdbId: metadata?.imdbId,
  );

  return MediaTitle(
    identity: identity,
    title: item.seriesName ?? item.name,
    availability: MediaAvailability.inLibrary,
    year: item.productionYear,
    overview: item.overview,
    posterUrl: imageUrl(
      metadata?.id ?? item.seriesId ?? item.id,
      tag: metadata?.imageTags?['Primary'] ?? item.imageTags?['Primary'],
    ),
    backdropUrl: metadata?.backdropImageTags?.isNotEmpty ?? false
        ? imageUrl(
            metadata!.id,
            type: 'Backdrop',
            tag: metadata.backdropImageTags!.first,
          )
        : null,
    jellyfinItemId: item.isPlayable ? item.id : null,
    jellyfinLookupId: item.id,
    jellyfinSeriesId: item.type == 'Series' ? item.id : item.seriesId,
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
    JellyseerrMediaStatus.available => MediaAvailability.available,
    JellyseerrMediaStatus.partiallyAvailable =>
      MediaAvailability.partiallyAvailable,
    JellyseerrMediaStatus.blocklisted => MediaAvailability.failed,
    JellyseerrMediaStatus.deleted => MediaAvailability.notAvailable,
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
    jellyseerrMediaId: result.mediaInfo?.jellyfinMediaId,
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
        ? MediaAvailability.available
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
    final keys = [
      ...title.identity.allKeys,
      if (title.jellyfinSeriesId != null) 'jellyfin:${title.jellyfinSeriesId}',
      if (title.jellyfinItemId != null) 'jellyfin:${title.jellyfinItemId}',
      if (title.jellyfinLookupId != null) 'jellyfin:${title.jellyfinLookupId}',
    ];
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
  final reads = _MediaReads();
  final indexFuture = ref.watch(mediaLibraryIndexProvider.future);
  final jellyfin = ref.watch(jellyfinClientProvider);
  final jellyseerr = ref.watch(jellyseerrClientProvider);
  final sonarr = ref.watch(sonarrClientProvider);
  final radarr = ref.watch(radarrClientProvider);

  String? jfImage(String id, {String type = 'Primary', String? tag}) =>
      jellyfin?.imageUrl(id, type: type, tag: tag);

  final pendingResults = Future.wait([
    reads.read<List<JellyfinItem>>(
      const MediaReadKey(IntegrationId.jellyfin, MediaReadOperation.resume),
      jellyfin != null,
      () => jellyfin?.getResumeItems() ?? Future.value(const []),
      const [],
    ),
    reads.read<List<JellyfinItem>>(
      const MediaReadKey(IntegrationId.jellyfin, MediaReadOperation.recent),
      jellyfin != null,
      () => jellyfin?.getLatestItems() ?? Future.value(const []),
      const [],
    ),
    reads.read<List<JellyseerrResult>>(
      const MediaReadKey(IntegrationId.jellyseerr, MediaReadOperation.trending),
      jellyseerr != null,
      () => jellyseerr?.discoverTrending() ?? Future.value(const []),
      const [],
    ),
    reads.read<List<ArrCalendarItem>>(
      const MediaReadKey(IntegrationId.sonarr, MediaReadOperation.calendar),
      sonarr != null,
      () => sonarr?.getCalendar() ?? Future.value(const []),
      const [],
    ),
    reads.read<List<ArrCalendarItem>>(
      const MediaReadKey(IntegrationId.radarr, MediaReadOperation.calendar),
      radarr != null,
      () => radarr?.getCalendar() ?? Future.value(const []),
      const [],
    ),
    reads.read<List<ArrQueueItem>>(
      const MediaReadKey(IntegrationId.sonarr, MediaReadOperation.queue),
      sonarr != null,
      () => ref.watch(sonarrQueueProvider.future),
      const [],
    ),
    reads.read<List<ArrQueueItem>>(
      const MediaReadKey(IntegrationId.radarr, MediaReadOperation.queue),
      radarr != null,
      () => ref.watch(radarrQueueProvider.future),
      const [],
    ),
  ]);

  // Library indexing and row/search requests are independent. Start them
  // together; a large library must not delay the first request elsewhere.
  final completed = await Future.wait<Object>([indexFuture, pendingResults]);
  final index = completed[0] as MediaLibraryIndex;
  reads.include(index);
  final results = completed[1] as List<dynamic>;

  List<MediaTitle> fromJellyfin(List<JellyfinItem> items) => dedupeTitles(
    items
        .map(
          (e) => mediaTitleFromJellyfin(
            e,
            series: index.jellyfinItem(e.seriesId),
            imageUrl: jfImage,
          ),
        )
        .whereType<MediaTitle>()
        .map((title) => index.enrich(title, preserveVerifiedPlayback: true)),
  );

  final comingSoon = dedupeTitles(
    [
      ...(results[3] as List<ArrCalendarItem>)
          .map((e) => mediaTitleFromCalendar(e, MediaKind.tv))
          .whereType<MediaTitle>(),
      ...(results[4] as List<ArrCalendarItem>)
          .map((e) => mediaTitleFromCalendar(e, MediaKind.movie))
          .whereType<MediaTitle>(),
    ].map((title) => index.enrich(title, preserveVerifiedPlayback: true)),
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
            availability: mediaTransferFromQueue(item).stage,
            downloadProgress: mediaTransferFromQueue(item).progress,
            transfers: List.unmodifiable([mediaTransferFromQueue(item)]),
          );
        })
        .map((title) => index.enrich(title, preserveVerifiedPlayback: true)),
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
            .map(
              (title) => index.enrich(title, preserveVerifiedPlayback: true),
            ),
      ),
    ),
    MediaRowData(id: MediaRowId.comingSoon, titles: comingSoon),
    MediaRowData(id: MediaRowId.downloading, titles: downloading),
  ];

  reads.publish(ref, [
    jellyfin?.healthSession,
    jellyseerr?.healthSession,
    sonarr?.healthSession,
    radarr?.healthSession,
  ]);
  return MediaReadList(
    rows.where((row) => row.titles.isNotEmpty),
    issues: reads.issues,
    successfulReads: reads.successful,
  );
}

/// Unified search: the library and the requestable catalogue at once,
/// merged so one title is one result no matter how many services know it.
@riverpod
Future<List<MediaTitle>> mediaSearch(Ref ref, String query) async {
  if (query.trim().isEmpty) return const [];
  final reads = _MediaReads();

  final indexFuture = ref.watch(mediaLibraryIndexProvider.future);
  final jellyfin = ref.watch(jellyfinClientProvider);
  final jellyseerr = ref.watch(jellyseerrClientProvider);
  final sonarr = ref.watch(sonarrClientProvider);
  final radarr = ref.watch(radarrClientProvider);

  final pendingResults = Future.wait([
    reads.read<List<JellyfinItem>>(
      const MediaReadKey(IntegrationId.jellyfin, MediaReadOperation.search),
      jellyfin != null,
      () => jellyfin?.search(query) ?? Future.value(const []),
      const [],
    ),
    reads.read<List<JellyseerrResult>>(
      const MediaReadKey(IntegrationId.jellyseerr, MediaReadOperation.search),
      jellyseerr != null,
      () => jellyseerr?.search(query) ?? Future.value(const []),
      const [],
    ),
    reads.read<List<ArrLookupResult>>(
      const MediaReadKey(IntegrationId.sonarr, MediaReadOperation.search),
      jellyseerr == null && sonarr != null,
      () => jellyseerr == null && sonarr != null
          ? sonarr.lookup(query)
          : Future.value(const []),
      const [],
    ),
    reads.read<List<ArrLookupResult>>(
      const MediaReadKey(IntegrationId.radarr, MediaReadOperation.search),
      jellyseerr == null && radarr != null,
      () => jellyseerr == null && radarr != null
          ? radarr.lookup(query)
          : Future.value(const []),
      const [],
    ),
  ]);

  // Library indexing and row/search requests are independent. Start them
  // together; a large library must not delay the first request elsewhere.
  final completed = await Future.wait<Object>([indexFuture, pendingResults]);
  final index = completed[0] as MediaLibraryIndex;
  reads.include(index);
  final results = completed[1] as List<dynamic>;

  // Library hits lead: something already playable is almost always what
  // the user meant, and deduping keeps the first occurrence.
  final titles = dedupeTitles(
    [
      ...(results[0] as List<JellyfinItem>)
          .map(
            (e) => mediaTitleFromJellyfin(
              e,
              series: index.jellyfinItem(e.seriesId),
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
      ...(results[2] as List<ArrLookupResult>).map(
        (item) => mediaTitleFromArrLookup(item, MediaKind.tv),
      ),
      ...(results[3] as List<ArrLookupResult>).map(
        (item) => mediaTitleFromArrLookup(item, MediaKind.movie),
      ),
    ].map((title) => index.enrich(title, preserveVerifiedPlayback: true)),
  );
  reads.publish(ref, [
    jellyfin?.healthSession,
    jellyseerr?.healthSession,
    sonarr?.healthSession,
    radarr?.healthSession,
  ]);
  return MediaReadList(
    titles,
    issues: reads.issues,
    successfulReads: reads.successful,
  );
}

MediaTitle mediaTitleFromArrLookup(ArrLookupResult result, MediaKind kind) {
  int? id(String key) => int.tryParse('${result.raw[key] ?? ''}');
  return MediaTitle(
    identity: MediaIdentity(
      kind: kind,
      tmdbId: id('tmdbId'),
      tvdbId: id('tvdbId'),
      imdbId: result.raw['imdbId'] as String?,
    ),
    title: result.title,
    year: result.year,
    overview: result.overview,
    posterUrl: result.posterUrl,
    availability: result.alreadyAdded
        ? MediaAvailability.monitored
        : MediaAvailability.notAvailable,
    arrItemId: result.alreadyAdded ? id('id') : null,
  );
}
