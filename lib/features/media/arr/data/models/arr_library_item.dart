/// One item already in a Sonarr or Radarr library (`GET /api/v3/series`
/// or `/movie`).
///
/// Unlike [ArrLookupResult] this isn't for adding things — it exists so
/// the media hub can index everything the *arr apps already track and
/// answer "do I have this?" for any title without a lookup round-trip
/// per title. The external ids are what make that index joinable with
/// Jellyfin and Jellyseerr.
class ArrLibraryItem {
  const ArrLibraryItem({
    required this.id,
    required this.title,
    required this.monitored,
    this.year,
    this.overview,
    this.posterUrl,
    this.tmdbId,
    this.tvdbId,
    this.imdbId,
    this.hasFile,
    this.statistics,
  });

  /// The *arr app's own row id — what Bazarr's `radarrId`/`seriesId`
  /// refer to, so this is the join back to subtitle status.
  final int id;
  final String title;
  final bool monitored;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final int? tmdbId;
  final int? tvdbId;
  final String? imdbId;

  /// Radarr only — Sonarr tracks files per episode, so series report
  /// completeness through [statistics] instead.
  final bool? hasFile;
  final ArrLibraryStatistics? statistics;

  /// True when the item is fully downloaded: a movie with its file, or a
  /// series with every episode present.
  bool get isComplete => hasFile ?? (statistics?.isComplete ?? false);

  factory ArrLibraryItem.fromJson(Map<String, dynamic> json) {
    final images = json['images'] as List<dynamic>? ?? const [];
    String? poster;
    for (final image in images) {
      final map = image as Map<String, dynamic>;
      if (map['coverType'] == 'poster') {
        poster = (map['remoteUrl'] ?? map['url']) as String?;
        break;
      }
    }

    final statistics = json['statistics'];

    return ArrLibraryItem(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? 'Unknown',
      monitored: json['monitored'] as bool? ?? false,
      year: json['year'] as int?,
      overview: json['overview'] as String?,
      posterUrl: poster,
      tmdbId: json['tmdbId'] as int?,
      tvdbId: json['tvdbId'] as int?,
      imdbId: json['imdbId'] as String?,
      hasFile: json['hasFile'] as bool?,
      statistics: statistics is Map<String, dynamic>
          ? ArrLibraryStatistics.fromJson(statistics)
          : null,
    );
  }
}

class ArrLibraryStatistics {
  const ArrLibraryStatistics({
    required this.episodeCount,
    required this.episodeFileCount,
  });

  final int episodeCount;
  final int episodeFileCount;

  bool get isComplete => episodeCount > 0 && episodeFileCount >= episodeCount;

  factory ArrLibraryStatistics.fromJson(Map<String, dynamic> json) =>
      ArrLibraryStatistics(
        episodeCount: json['episodeCount'] as int? ?? 0,
        episodeFileCount: json['episodeFileCount'] as int? ?? 0,
      );
}
