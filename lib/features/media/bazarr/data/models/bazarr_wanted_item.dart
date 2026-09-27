/// A movie or episode with missing subtitle languages, from Bazarr's
/// `/api/movies/wanted` or `/api/episodes/wanted`.
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

  String get identityKey =>
      isMovie ? 'movie.$radarrId' : 'episode.$seriesId.$episodeId';

  factory BazarrWantedItem.fromJson(Map<String, dynamic> json) {
    final rawMissing = json['missing_subtitles'];
    if (rawMissing != null && rawMissing is! List<dynamic>) {
      throw const FormatException('Invalid Bazarr missing subtitles');
    }
    final missing = rawMissing as List<dynamic>? ?? const <dynamic>[];
    if (missing.length > 32) {
      throw const FormatException('Too many Bazarr subtitle languages');
    }
    final radarrId = _positiveId(json['radarrId']);
    final seriesId = _positiveId(json['sonarrSeriesId'] ?? json['seriesId']);
    final episodeId = _positiveId(json['sonarrEpisodeId'] ?? json['episodeId']);
    if ((radarrId != null) == (seriesId != null && episodeId != null) ||
        (seriesId == null) != (episodeId == null)) {
      throw const FormatException('Invalid Bazarr media identity');
    }
    final rawTitle = json['title'] ?? json['seriesTitle'];
    if (rawTitle is! String) {
      throw const FormatException('Invalid Bazarr title');
    }
    final title = rawTitle.trim();
    if (title.isEmpty || title.length > 512) {
      throw const FormatException('Invalid Bazarr title');
    }
    final languages = <BazarrMissingLanguage>[];
    final seen = <String>{};
    for (final value in missing) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid Bazarr subtitle language');
      }
      final language = BazarrMissingLanguage.fromJson(value);
      if (seen.add(language.code)) languages.add(language);
    }
    return BazarrWantedItem(
      radarrId: radarrId,
      seriesId: seriesId,
      episodeId: episodeId,
      title: title,
      missingLanguages: List.unmodifiable(languages),
    );
  }

  static int? _positiveId(Object? raw) {
    if (raw == null) return null;
    final value = switch (raw) {
      int value => value,
      num value when value.isFinite && value == value.roundToDouble() =>
        value.toInt(),
      String value => int.tryParse(value),
      _ => null,
    };
    if (value == null || value < 1 || value > 0x7fffffff) {
      throw const FormatException('Invalid Bazarr media identity');
    }
    return value;
  }
}

class BazarrMissingLanguage {
  const BazarrMissingLanguage({required this.code, this.name});

  final String code;
  final String? name;

  String get label => name ?? code;

  factory BazarrMissingLanguage.fromJson(Map<String, dynamic> json) {
    final code = normalizeCode(json['code2'] ?? json['code']);
    final rawName = json['name'];
    if (rawName != null && rawName is! String) {
      throw const FormatException('Invalid Bazarr language name');
    }
    final name = (rawName as String?)?.trim();
    if (name != null && (name.isEmpty || name.length > 64)) {
      throw const FormatException('Invalid Bazarr language name');
    }
    return BazarrMissingLanguage(code: code, name: name);
  }

  static String normalizeCode(Object? raw) {
    if (raw is! String) {
      throw const FormatException('Invalid Bazarr language code');
    }
    final value = raw.trim().toLowerCase().replaceAll('_', '-');
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2}|-[0-9]{3})?$').hasMatch(value)) {
      throw const FormatException('Invalid Bazarr language code');
    }
    return value;
  }
}
