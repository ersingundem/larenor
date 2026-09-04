class ArrCalendarItem {
  const ArrCalendarItem({
    required this.title,
    this.subtitle,
    this.date,
    this.hasFile = false,
    this.tmdbId,
    this.tvdbId,
    this.imdbId,
    this.posterUrl,
  });

  final String title;
  final String? subtitle;
  final DateTime? date;
  final bool hasFile;

  /// External ids, read from the nested parent object for Sonarr-style
  /// episode entries and from the entry itself for Radarr-style movie
  /// entries — so a "coming soon" row can link straight through to the
  /// unified title page.
  final int? tmdbId;
  final int? tvdbId;
  final String? imdbId;
  final String? posterUrl;

  /// Sonarr calendar entries are episodes (title = episode title, with a
  /// nested `series.title`); Radarr's are the movies themselves; Lidarr's
  /// are albums (nested `artist.artistName`); Readarr's are books (nested
  /// `author.authorName`). One lenient parser covers all four rather than
  /// near-identical models per service.
  factory ArrCalendarItem.fromJson(Map<String, dynamic> json) {
    final series = json['series'] as Map<String, dynamic>?;
    final parentTitle =
        series?['title'] as String? ??
        (json['artist'] as Map<String, dynamic>?)?['artistName'] as String? ??
        (json['author'] as Map<String, dynamic>?)?['authorName'] as String?;
    final season = json['seasonNumber'] as int?;
    final episode = json['episodeNumber'] as int?;

    final dateString =
        json['airDateUtc'] as String? ??
        json['inCinemas'] as String? ??
        json['digitalRelease'] as String? ??
        json['physicalRelease'] as String? ??
        json['releaseDate'] as String?;

    // Episode entries carry their ids on the nested series; movie
    // entries carry them at the top level.
    final idSource = series ?? json;

    return ArrCalendarItem(
      title: parentTitle ?? json['title'] as String? ?? 'Unknown',
      subtitle: parentTitle != null
          ? '${_episodeCode(season, episode)} ${json['title'] ?? ''}'.trim()
          : null,
      date: dateString == null ? null : DateTime.tryParse(dateString),
      hasFile: json['hasFile'] as bool? ?? false,
      tmdbId: idSource['tmdbId'] as int?,
      tvdbId: idSource['tvdbId'] as int?,
      imdbId: idSource['imdbId'] as String?,
      posterUrl: _posterFrom(idSource['images'] as List<dynamic>?),
    );
  }

  static String? _posterFrom(List<dynamic>? images) {
    for (final image in images ?? const []) {
      final map = image as Map<String, dynamic>;
      if (map['coverType'] == 'poster') {
        return (map['remoteUrl'] ?? map['url']) as String?;
      }
    }
    return null;
  }

  static String _episodeCode(int? season, int? episode) {
    if (season == null || episode == null) return '';
    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }
}
