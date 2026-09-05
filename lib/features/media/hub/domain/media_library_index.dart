import '../../../health/data/integration_health.dart';
import '../../arr/data/models/arr_library_item.dart';
import '../../arr/data/models/arr_queue_item.dart';
import '../../jellyfin/data/models/jellyfin_item.dart';
import '../../jellyseerr/data/models/jellyseerr_request_item.dart';
import 'media_identity.dart';
import 'media_title.dart';
import 'media_read_result.dart';

/// Source evidence stays independent: a series can have files and an active
/// transfer at the same time. Arr/Seerr availability never grants playback.
class MediaLibraryEntry {
  const MediaLibraryEntry({
    required this.identity,
    this.title,
    this.year,
    this.overview,
    this.posterUrl,
    this.jellyfinItemId,
    this.jellyfinLookupId,
    this.jellyfinSeriesId,
    this.jellyfinPresent = false,
    this.playedFraction,
    this.arrItemId,
    this.monitored,
    this.complete,
    this.partial = false,
    this.downloadProgress,
    this.transfers = const [],
    this.seasonCoverage = const [],
    this.requestStatus,
    this.requestId,
  });
  final MediaIdentity identity;
  final String? title;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final String? jellyfinItemId;
  final String? jellyfinLookupId;
  final String? jellyfinSeriesId;
  final bool jellyfinPresent;
  final double? playedFraction;
  final int? arrItemId;
  final bool? monitored;
  final bool? complete;
  final bool partial;
  final double? downloadProgress;
  final List<MediaTransferProgress> transfers;
  final List<MediaSeasonCoverage> seasonCoverage;
  final JellyseerrRequestStatus? requestStatus;
  final int? requestId;

  MediaLibraryEntry mergedWith(MediaLibraryEntry other) {
    final latestRequest = (requestId ?? -1) >= (other.requestId ?? -1)
        ? this
        : other;
    final mergedTransfers = <String, MediaTransferProgress>{};
    for (final transfer in [...other.transfers, ...transfers]) {
      mergedTransfers['${transfer.source.name}:${transfer.id}'] = transfer;
    }
    final orderedTransfers = mergedTransfers.values.toList()
      ..sort(
        (a, b) =>
            '${a.source.name}:${a.id}'.compareTo('${b.source.name}:${b.id}'),
      );
    return MediaLibraryEntry(
      identity: identity.mergedWith(other.identity),
      title: title ?? other.title,
      year: year ?? other.year,
      overview: overview ?? other.overview,
      posterUrl: posterUrl ?? other.posterUrl,
      jellyfinItemId: jellyfinItemId ?? other.jellyfinItemId,
      jellyfinLookupId: jellyfinLookupId ?? other.jellyfinLookupId,
      jellyfinSeriesId: jellyfinSeriesId ?? other.jellyfinSeriesId,
      jellyfinPresent: jellyfinPresent || other.jellyfinPresent,
      playedFraction: playedFraction ?? other.playedFraction,
      arrItemId: arrItemId ?? other.arrItemId,
      monitored: monitored ?? other.monitored,
      complete: complete ?? other.complete,
      partial: partial || other.partial,
      downloadProgress: _singleProgress(orderedTransfers),
      transfers: List.unmodifiable(orderedTransfers),
      seasonCoverage: List.unmodifiable([
        ...seasonCoverage,
        ...other.seasonCoverage,
      ]),
      requestStatus: latestRequest.requestStatus,
      requestId: latestRequest.requestId,
    );
  }

  MediaAvailability get availability {
    if (partial) return MediaAvailability.partiallyAvailable;
    if (jellyfinPresent) return MediaAvailability.inLibrary;
    if (complete == true) return MediaAvailability.available;
    if (transfers.isNotEmpty) return _transferSummary(transfers);
    if (requestStatus == JellyseerrRequestStatus.declined ||
        requestStatus == JellyseerrRequestStatus.failed) {
      return MediaAvailability.failed;
    }
    if (requestStatus == JellyseerrRequestStatus.pendingApproval ||
        requestStatus == JellyseerrRequestStatus.approved) {
      return MediaAvailability.requested;
    }
    if (arrItemId != null && monitored == true) {
      return MediaAvailability.monitored;
    }
    if (requestStatus == JellyseerrRequestStatus.unknown ||
        requestStatus == JellyseerrRequestStatus.completed) {
      return MediaAvailability.unknown;
    }
    return MediaAvailability.notAvailable;
  }
}

/// Immutable, account-scoped evidence built once per refresh; no I/O per title.
class MediaLibraryIndex {
  MediaLibraryIndex._(
    this._byKey,
    this._jellyfinById, {
    this.readIssues = const [],
    this.successfulReads = const {},
    this.readAt,
  });
  final List<MediaReadIssue> readIssues;
  final Set<MediaReadKey> successfulReads;
  final DateTime? readAt;
  final Map<String, MediaLibraryEntry> _byKey;
  final Map<String, JellyfinItem> _jellyfinById;
  JellyfinItem? jellyfinItem(String? id) => _jellyfinById[id];
  Iterable<JellyfinItem> get jellyfinItems => _jellyfinById.values;
  static final empty = MediaLibraryIndex._(const {}, const {});
  bool get isEmpty => _byKey.isEmpty;

  MediaLibraryEntry? lookup(MediaIdentity identity) {
    for (final key in identity.allKeys) {
      final hit = _byKey[key];
      if (hit != null && identity.matches(hit.identity)) return hit;
    }
    return null;
  }

  MediaAvailability availabilityOf(MediaIdentity identity) =>
      lookup(identity)?.availability ?? MediaAvailability.notAvailable;

  /// Current indexed metadata, useful for a deep link outside hub feeds.
  MediaTitle? titleFor(MediaIdentity identity) {
    final entry = lookup(identity);
    if (entry?.title == null) return null;
    return enrich(
      MediaTitle(
        identity: entry!.identity,
        title: entry.title!,
        availability: entry.availability,
        year: entry.year,
        overview: entry.overview,
        posterUrl: entry.posterUrl,
      ),
    );
  }

  /// By default only this index may provide account-bound evidence. Set the
  /// flag only for a freshly parsed response from the same provider generation
  /// (e.g. a resume Episode absent from the Movie/Series index), never route extra.
  MediaTitle enrich(MediaTitle title, {bool preserveVerifiedPlayback = false}) {
    final entry = lookup(title.identity);
    final sourceTitle = preserveVerifiedPlayback;
    final jfReadFailed = readIssues.any(
      (issue) =>
          issue.read.service == IntegrationId.jellyfin &&
          issue.read.operation == MediaReadOperation.library,
    );
    final item = _jellyfinById[title.jellyfinItemId];
    final verifiedItem =
        item != null && item.isPlayable && (entry?.jellyfinItemId == item.id);
    final playback = sourceTitle && title.isPlayable
        ? title.jellyfinItemId
        : verifiedItem
        ? item.id
        : entry?.jellyfinItemId;
    final transfers =
        entry?.transfers ??
        (sourceTitle ? title.transfers : const <MediaTransferProgress>[]);
    final coverage =
        entry?.seasonCoverage ??
        (sourceTitle ? title.seasonCoverage : const <MediaSeasonCoverage>[]);
    var availability =
        entry?.availability ??
        (sourceTitle ? title.availability : MediaAvailability.notAvailable);
    if (sourceTitle &&
        entry != null &&
        (availability == MediaAvailability.notAvailable ||
            availability == MediaAvailability.monitored) &&
        title.availability != MediaAvailability.notAvailable) {
      availability = title.availability;
    }
    if (entry == null && !sourceTitle && readIssues.isNotEmpty) {
      availability = MediaAvailability.unknown;
    }
    // A present Series container never disproves Seerr's partial coverage.
    if (sourceTitle &&
        title.availability == MediaAvailability.partiallyAvailable &&
        title.isTv) {
      availability = MediaAvailability.partiallyAvailable;
    }
    return title.copyWith(
      identity: entry == null
          ? title.identity
          : title.identity.mergedWith(entry.identity),
      availability: availability,
      title: entry?.title ?? title.title,
      jellyfinItemId: playback,
      jellyfinLookupId: sourceTitle
          ? title.jellyfinLookupId ?? entry?.jellyfinLookupId
          : entry?.jellyfinLookupId,
      jellyfinSeriesId: sourceTitle
          ? title.jellyfinSeriesId ?? entry?.jellyfinSeriesId
          : entry?.jellyfinSeriesId,
      jellyseerrMediaId: sourceTitle ? title.jellyseerrMediaId : null,
      playedFraction: sourceTitle && title.jellyfinItemId == playback
          ? title.playedFraction ?? entry?.playedFraction
          : entry?.playedFraction,
      downloadProgress: transfers.isEmpty ? null : _singleProgress(transfers),
      arrItemId: entry?.arrItemId,
      monitored: entry?.monitored,
      transfers: transfers,
      seasonCoverage: coverage,
      requestStatus:
          entry?.requestStatus ?? (sourceTitle ? title.requestStatus : null),
      readAt: readAt,
      isStale: jfReadFailed && !(sourceTitle && title.isPlayable),
      readIssues: readIssues,
    );
  }

  static MediaLibraryIndex build({
    List<JellyfinItem> jellyfinItems = const [],
    List<ArrLibraryItem> sonarrLibrary = const [],
    List<ArrLibraryItem> radarrLibrary = const [],
    List<ArrQueueItem> queue = const [],
    List<JellyseerrRequestItem> requests = const [],
    Iterable<MediaReadIssue> readIssues = const [],
    Iterable<MediaReadKey> successfulReads = const [],
    DateTime? readAt,
  }) {
    final byKey = <String, MediaLibraryEntry>{};
    void add(MediaLibraryEntry entry) {
      final keys = entry.identity.allKeys;
      if (keys.isEmpty) return;
      var merged = entry;
      final seen = <MediaLibraryEntry>{};
      for (final key in keys) {
        final existing = byKey[key];
        if (existing != null &&
            seen.add(existing) &&
            merged.identity.matches(existing.identity)) {
          merged = merged.mergedWith(existing);
        }
      }
      for (final key in merged.identity.allKeys) {
        // Contradictory higher-priority metadata must not create a cross-title
        // playback bridge through a lower-priority id.
        final old = byKey[key];
        if (old == null || old.identity.matches(merged.identity)) {
          byKey[key] = merged;
        }
      }
    }

    for (final item in jellyfinItems) {
      if (item.type != 'Movie' && item.type != 'Series') continue;
      final kind = jellyfinKindOf(item)!;
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
          title: item.name,
          year: item.productionYear,
          overview: item.overview,
          jellyfinItemId: item.isPlayable ? item.id : null,
          jellyfinLookupId: item.id,
          jellyfinSeriesId: item.type == 'Series' ? item.id : null,
          jellyfinPresent: true,
          playedFraction: item.isPlayable && item.playedFraction > 0
              ? item.playedFraction
              : null,
        ),
      );
    }
    void addArr(
      List<ArrLibraryItem> items,
      MediaKind kind,
      IntegrationId source,
    ) {
      for (final item in items) {
        final identity = MediaIdentity(
          kind: kind,
          tmdbId: item.tmdbId,
          tvdbId: item.tvdbId,
          imdbId: item.imdbId,
        );
        final have = item.statistics?.episodeFileCount;
        add(
          MediaLibraryEntry(
            identity: identity,
            title: item.title,
            year: item.year,
            overview: item.overview,
            posterUrl: item.posterUrl,
            arrItemId: item.id,
            monitored: item.monitored,
            complete: item.isComplete,
            partial:
                kind == MediaKind.tv &&
                have != null &&
                have > 0 &&
                !item.isComplete,
            seasonCoverage: List.unmodifiable(
              item.seasons.map(
                (season) => MediaSeasonCoverage(
                  seasonNumber: season.seasonNumber,
                  source: source,
                  expectedEpisodeCount: season.statistics?.totalEpisodeCount,
                  downloadedEpisodeCount: season.statistics?.episodeFileCount,
                ),
              ),
            ),
          ),
        );
      }
    }

    addArr(sonarrLibrary, MediaKind.tv, IntegrationId.sonarr);
    addArr(radarrLibrary, MediaKind.movie, IntegrationId.radarr);
    final sonarrById = {for (final item in sonarrLibrary) item.id: item};
    final radarrById = {for (final item in radarrLibrary) item.id: item};
    for (final item in queue) {
      final kind = item.seriesId != null ? MediaKind.tv : MediaKind.movie;
      var identity = MediaIdentity(
        kind: kind,
        tmdbId: item.tmdbId,
        tvdbId: item.tvdbId,
        imdbId: item.imdbId,
      );
      // Queue APIs may omit nested metadata. Resolve once against the already
      // fetched library by the *arr row id; never match titles by display name.
      if (identity.isEmpty) {
        final library = kind == MediaKind.tv ? sonarrById : radarrById;
        final candidate = library[item.seriesId ?? item.movieId];
        if (candidate != null) {
          identity = MediaIdentity(
            kind: kind,
            tmdbId: candidate.tmdbId,
            tvdbId: candidate.tvdbId,
            imdbId: candidate.imdbId,
          );
        }
      }
      final transfer = mediaTransferFromQueue(item);
      final metadata = (kind == MediaKind.tv
          ? sonarrById
          : radarrById)[item.seriesId ?? item.movieId];
      add(
        MediaLibraryEntry(
          identity: identity,
          title: metadata?.title ?? item.title,
          arrItemId: item.seriesId ?? item.movieId,
          downloadProgress: transfer.progress,
          transfers: List.unmodifiable([transfer]),
        ),
      );
    }
    for (final request in requests) {
      if (request.mediaType != 'movie' && request.mediaType != 'tv') continue;
      final tmdbId = request.media?.tmdbId;
      if (tmdbId == null || tmdbId <= 0) continue;
      add(
        MediaLibraryEntry(
          identity: MediaIdentity(
            kind: request.mediaType == 'tv' ? MediaKind.tv : MediaKind.movie,
            tmdbId: tmdbId,
          ),
          title: request.media?.displayTitle,
          requestId: request.id,
          requestStatus: request.status,
        ),
      );
    }
    return MediaLibraryIndex._(
      Map.unmodifiable(byKey),
      Map.unmodifiable({for (final item in jellyfinItems) item.id: item}),
      readIssues: orderedMediaIssues(readIssues),
      successfulReads: Set.unmodifiable(successfulReads),
      readAt: readAt,
    );
  }
}

// Official Sonarr/Radarr QueueResource and TrackedDownload enums (2026-09-05):
// github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/Queue/QueueStatus.cs
// github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/Download/TrackedDownloads/TrackedDownload.cs
MediaTransferProgress mediaTransferFromQueue(ArrQueueItem item) {
  final state = item.trackedDownloadState?.toLowerCase();
  final health = item.trackedDownloadStatus?.toLowerCase();
  final status = item.status.toLowerCase();
  final MediaAvailability stage;
  if (health == 'error' ||
      health == 'warning' ||
      state == 'importblocked' ||
      state == 'failedpending' ||
      state == 'failed') {
    stage = MediaAvailability.failed;
  } else if (state == 'imported') {
    stage = MediaAvailability.available;
  } else if (state == 'importpending' || state == 'importing') {
    stage = MediaAvailability.importing;
  } else if (state == 'ignored') {
    stage = MediaAvailability.unknown;
  } else {
    stage = switch (status) {
      'queued' || 'delay' || 'fallback' => MediaAvailability.queued,
      'paused' => MediaAvailability.paused,
      'downloading' => MediaAvailability.downloading,
      'completed' => MediaAvailability.importing,
      'failed' || 'warning' => MediaAvailability.failed,
      _ => MediaAvailability.unknown,
    };
  }
  final rawProgress = item.progressFraction;
  final progress =
      rawProgress != null &&
          rawProgress.isFinite &&
          rawProgress >= 0 &&
          rawProgress <= 1
      ? rawProgress
      : null;
  return MediaTransferProgress(
    id: '${item.id}',
    source: item.seriesId != null ? IntegrationId.sonarr : IntegrationId.radarr,
    stage: stage,
    progress: progress,
    seasonNumber: item.seasonNumber,
  );
}

double? _singleProgress(List<MediaTransferProgress> transfers) =>
    transfers.length == 1 ? transfers.single.progress : null;

MediaAvailability _transferSummary(List<MediaTransferProgress> transfers) {
  const priority = [
    MediaAvailability.failed,
    MediaAvailability.importing,
    MediaAvailability.downloading,
    MediaAvailability.paused,
    MediaAvailability.queued,
    MediaAvailability.unknown,
    MediaAvailability.available,
  ];
  for (final stage in priority) {
    if (transfers.any((transfer) => transfer.stage == stage)) return stage;
  }
  return MediaAvailability.unknown;
}

MediaKind? jellyfinKindOf(JellyfinItem item) => switch (item.type) {
  'Movie' => MediaKind.movie,
  'Series' || 'Season' || 'Episode' => MediaKind.tv,
  _ => null,
};
