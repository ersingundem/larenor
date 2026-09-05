import '../../../health/data/integration_health.dart';
import '../../jellyseerr/data/models/jellyseerr_request_item.dart';
import 'media_identity.dart';
import 'media_read_result.dart';

/// What the app can currently do with a title, in the order the hub
/// prefers to show it.
enum MediaAvailability {
  /// Present in the currently connected Jellyfin account. Not a promise that
  /// every episode exists or that a device can negotiate playback.
  inLibrary,
  downloading,
  requested,
  monitored,
  notAvailable,
  queued,
  paused,
  importing,
  partiallyAvailable,

  /// A source reports files/availability, without verified Jellyfin playback.
  available,
  failed,
  unknown,
}

/// One transfer remains independent from a title's existing playable files.
class MediaTransferProgress {
  const MediaTransferProgress({
    required this.id,
    required this.source,
    required this.stage,
    this.progress,
    this.seasonNumber,
  });
  final String id;
  final IntegrationId source;
  final MediaAvailability stage;
  final double? progress;
  final int? seasonNumber;
}

/// Counts from one source; downloaded files are not playable-item evidence.
/// Null means the source did not provide that count, never zero.
class MediaSeasonCoverage {
  const MediaSeasonCoverage({
    required this.seasonNumber,
    required this.source,
    this.expectedEpisodeCount,
    this.downloadedEpisodeCount,
    this.playableEpisodeCount,
  });
  final int seasonNumber;
  final IntegrationId source;
  final int? expectedEpisodeCount;
  final int? downloadedEpisodeCount;
  final int? playableEpisodeCount;
}

/// One title, as the hub renders it — deliberately service-agnostic, so a
/// poster row doesn't care whether its contents came from Jellyfin, a
/// Jellyseerr discover feed or an *arr calendar.
class MediaTitle {
  const MediaTitle({
    required this.identity,
    required this.title,
    required this.availability,
    this.year,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.jellyfinItemId,
    this.jellyfinLookupId,
    this.jellyfinSeriesId,
    this.playedFraction,
    this.downloadProgress,
    this.rating,
    this.arrItemId,
    this.monitored,
    this.jellyseerrMediaId,
    this.transfers = const [],
    this.seasonCoverage = const [],
    this.requestStatus,
    this.readAt,
    this.isStale = false,
    this.readIssues = const [],
  });

  final MediaIdentity identity;
  final String title;
  final MediaAvailability availability;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;

  /// A currently verified Movie/Episode candidate. PlaybackInfo still
  /// negotiates actual device/session support before the player starts.
  final String? jellyfinItemId;

  /// Read-only current-account metadata lookup, including unknown playback
  /// eligibility. This ID never enables playback by itself.
  final String? jellyfinLookupId;
  final String? jellyfinSeriesId;

  /// Resume position, 0–1, when Jellyfin has watch progress for it.
  final double? playedFraction;

  /// Grab progress, 0–1, when it's in an *arr queue.
  final double? downloadProgress;
  final double? rating;

  /// The Sonarr/Radarr library row id — the join back to Bazarr's
  /// subtitle records, which key on the *arr's internal id rather than an
  /// external one.
  final int? arrItemId;
  final bool? monitored;

  /// A Seerr association is a resolver hint, not an authenticated playback ID.
  final String? jellyseerrMediaId;
  final List<MediaTransferProgress> transfers;
  final List<MediaSeasonCoverage> seasonCoverage;
  final JellyseerrRequestStatus? requestStatus;

  /// Time of the library read backing this snapshot, not a cache access time.
  final DateTime? readAt;
  final bool isStale;
  final List<MediaReadIssue> readIssues;

  bool get isPlayable => !isStale && jellyfinItemId != null;

  bool get isTv => identity.kind == MediaKind.tv;

  static const _unset = Object();

  MediaTitle copyWith({
    MediaIdentity? identity,
    String? title,
    MediaAvailability? availability,
    Object? year = _unset,
    Object? overview = _unset,
    Object? posterUrl = _unset,
    Object? backdropUrl = _unset,
    Object? jellyfinItemId = _unset,
    Object? jellyfinLookupId = _unset,
    Object? jellyfinSeriesId = _unset,
    Object? playedFraction = _unset,
    Object? downloadProgress = _unset,
    Object? rating = _unset,
    Object? arrItemId = _unset,
    Object? monitored = _unset,
    Object? jellyseerrMediaId = _unset,
    List<MediaTransferProgress>? transfers,
    List<MediaSeasonCoverage>? seasonCoverage,
    Object? requestStatus = _unset,
    Object? readAt = _unset,
    bool? isStale,
    List<MediaReadIssue>? readIssues,
  }) => MediaTitle(
    identity: identity ?? this.identity,
    title: title ?? this.title,
    availability: availability ?? this.availability,
    year: identical(year, _unset) ? this.year : year as int?,
    overview: identical(overview, _unset) ? this.overview : overview as String?,
    posterUrl: identical(posterUrl, _unset)
        ? this.posterUrl
        : posterUrl as String?,
    backdropUrl: identical(backdropUrl, _unset)
        ? this.backdropUrl
        : backdropUrl as String?,
    jellyfinItemId: identical(jellyfinItemId, _unset)
        ? this.jellyfinItemId
        : jellyfinItemId as String?,
    jellyfinLookupId: identical(jellyfinLookupId, _unset)
        ? this.jellyfinLookupId
        : jellyfinLookupId as String?,
    jellyfinSeriesId: identical(jellyfinSeriesId, _unset)
        ? this.jellyfinSeriesId
        : jellyfinSeriesId as String?,
    playedFraction: identical(playedFraction, _unset)
        ? this.playedFraction
        : playedFraction as double?,
    downloadProgress: identical(downloadProgress, _unset)
        ? this.downloadProgress
        : downloadProgress as double?,
    rating: identical(rating, _unset) ? this.rating : rating as double?,
    arrItemId: identical(arrItemId, _unset)
        ? this.arrItemId
        : arrItemId as int?,
    monitored: identical(monitored, _unset)
        ? this.monitored
        : monitored as bool?,
    jellyseerrMediaId: identical(jellyseerrMediaId, _unset)
        ? this.jellyseerrMediaId
        : jellyseerrMediaId as String?,
    transfers: transfers ?? this.transfers,
    seasonCoverage: seasonCoverage ?? this.seasonCoverage,
    requestStatus: identical(requestStatus, _unset)
        ? this.requestStatus
        : requestStatus as JellyseerrRequestStatus?,
    readAt: identical(readAt, _unset) ? this.readAt : readAt as DateTime?,
    isStale: isStale ?? this.isStale,
    readIssues: readIssues ?? this.readIssues,
  );
}
