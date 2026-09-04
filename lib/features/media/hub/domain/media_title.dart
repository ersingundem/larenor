import 'media_identity.dart';

/// What the app can currently do with a title, in the order the hub
/// prefers to show it.
enum MediaAvailability {
  /// Downloaded and playable in Jellyfin.
  inLibrary,

  /// Tracked by Sonarr/Radarr with a grab in progress.
  downloading,

  /// Requested through Jellyseerr, not yet grabbed.
  requested,

  /// In a Sonarr/Radarr library and monitored, but nothing downloaded.
  monitored,

  /// Known to the catalogue but not tracked anywhere.
  notAvailable,
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
    this.playedFraction,
    this.downloadProgress,
    this.rating,
    this.arrItemId,
    this.monitored,
  });

  final MediaIdentity identity;
  final String title;
  final MediaAvailability availability;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;

  /// Set when the title resolves to something in Jellyfin — this is what
  /// makes Play possible.
  final String? jellyfinItemId;

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

  bool get isPlayable => jellyfinItemId != null;

  bool get isTv => identity.kind == MediaKind.tv;

  MediaTitle copyWith({
    MediaIdentity? identity,
    String? title,
    MediaAvailability? availability,
    int? year,
    String? overview,
    String? posterUrl,
    String? backdropUrl,
    String? jellyfinItemId,
    double? playedFraction,
    double? downloadProgress,
    double? rating,
    int? arrItemId,
    bool? monitored,
  }) => MediaTitle(
    identity: identity ?? this.identity,
    title: title ?? this.title,
    availability: availability ?? this.availability,
    year: year ?? this.year,
    overview: overview ?? this.overview,
    posterUrl: posterUrl ?? this.posterUrl,
    backdropUrl: backdropUrl ?? this.backdropUrl,
    jellyfinItemId: jellyfinItemId ?? this.jellyfinItemId,
    playedFraction: playedFraction ?? this.playedFraction,
    downloadProgress: downloadProgress ?? this.downloadProgress,
    rating: rating ?? this.rating,
    arrItemId: arrItemId ?? this.arrItemId,
    monitored: monitored ?? this.monitored,
  );
}
