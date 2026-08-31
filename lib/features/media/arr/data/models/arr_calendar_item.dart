class ArrCalendarItem {
  const ArrCalendarItem({
    required this.title,
    this.subtitle,
    this.date,
    this.hasFile = false,
  });

  final String title;
  final String? subtitle;
  final DateTime? date;
  final bool hasFile;

  /// Sonarr calendar entries are episodes (title = episode title, with a
  /// nested `series.title`); Radarr's are the movies themselves. One
  /// lenient parser covers both rather than two near-identical models.
  factory ArrCalendarItem.fromJson(Map<String, dynamic> json) {
    final seriesTitle =
        (json['series'] as Map<String, dynamic>?)?['title'] as String?;
    final season = json['seasonNumber'] as int?;
    final episode = json['episodeNumber'] as int?;

    final dateString =
        json['airDateUtc'] as String? ??
        json['inCinemas'] as String? ??
        json['digitalRelease'] as String? ??
        json['physicalRelease'] as String?;

    return ArrCalendarItem(
      title: seriesTitle ?? json['title'] as String? ?? 'Unknown',
      subtitle: seriesTitle != null
          ? '${_episodeCode(season, episode)} ${json['title'] ?? ''}'.trim()
          : null,
      date: dateString == null ? null : DateTime.tryParse(dateString),
      hasFile: json['hasFile'] as bool? ?? false,
    );
  }

  static String _episodeCode(int? season, int? episode) {
    if (season == null || episode == null) return '';
    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }
}
