/// A movie or episode with missing subtitle languages, from Bazarr's
/// `/api/movies/wanted` or `/api/episodes/wanted`. Field names for the
/// series/episode identifiers aren't fully verified against a live
/// server, so both plausible key spellings are tried.
class BazarrWantedItem {
  const BazarrWantedItem({
    required this.radarrId,
    required this.seriesId,
    required this.episodeId,
    required this.title,
    required this.missingLanguages,
  });

  final int? radarrId;
  final int? seriesId;
  final int? episodeId;
  final String title;
  final List<BazarrMissingLanguage> missingLanguages;

  bool get isMovie => radarrId != null;

  factory BazarrWantedItem.fromJson(Map<String, dynamic> json) {
    final missing = json['missing_subtitles'] as List<dynamic>? ?? const [];
    return BazarrWantedItem(
      radarrId: (json['radarrId'] as num?)?.toInt(),
      seriesId:
          (json['sonarrSeriesId'] as num?)?.toInt() ??
          (json['seriesId'] as num?)?.toInt(),
      episodeId:
          (json['sonarrEpisodeId'] as num?)?.toInt() ??
          (json['episodeId'] as num?)?.toInt(),
      title:
          json['title'] as String? ??
          json['seriesTitle'] as String? ??
          'Unknown',
      missingLanguages: missing
          .map((e) => BazarrMissingLanguage.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class BazarrMissingLanguage {
  const BazarrMissingLanguage({required this.code, this.name});

  final String code;
  final String? name;

  String get label => name ?? code;

  factory BazarrMissingLanguage.fromJson(Map<String, dynamic> json) {
    final code = json['code2'] as String? ?? json['code'] as String? ?? '??';
    return BazarrMissingLanguage(code: code, name: json['name'] as String?);
  }
}
