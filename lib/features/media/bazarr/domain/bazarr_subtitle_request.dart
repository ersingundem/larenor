import '../data/models/bazarr_wanted_item.dart';

enum BazarrSubtitleKind { movie, episode }

/// Versioned, bounded request derived only from the exact current wanted row.
final class BazarrSubtitleRequest {
  BazarrSubtitleRequest._({
    required this.kind,
    required this.language,
    required this.radarrId,
    required this.seriesId,
    required this.episodeId,
  });

  static const schemaVersion = 1;

  factory BazarrSubtitleRequest.fromWanted(
    BazarrWantedItem item,
    BazarrMissingLanguage language,
  ) {
    final normalized = BazarrMissingLanguage.normalizeCode(language.code);
    if (!item.missingLanguages.any(
      (candidate) => _sameLanguage(candidate.code, normalized),
    )) {
      throw const FormatException('Subtitle language is no longer missing');
    }
    if (item.isMovie) {
      if (item.radarrId == null ||
          item.seriesId != null ||
          item.episodeId != null) {
        throw const FormatException('Invalid movie subtitle target');
      }
      return BazarrSubtitleRequest._(
        kind: BazarrSubtitleKind.movie,
        language: normalized,
        radarrId: item.radarrId,
        seriesId: null,
        episodeId: null,
      );
    }
    if (item.radarrId != null ||
        item.seriesId == null ||
        item.episodeId == null) {
      throw const FormatException('Invalid episode subtitle target');
    }
    return BazarrSubtitleRequest._(
      kind: BazarrSubtitleKind.episode,
      language: normalized,
      radarrId: null,
      seriesId: item.seriesId,
      episodeId: item.episodeId,
    );
  }

  final BazarrSubtitleKind kind;
  final String language;
  final int? radarrId;
  final int? seriesId;
  final int? episodeId;

  String get key => kind == BazarrSubtitleKind.movie
      ? 'movie.$radarrId.$language'
      : 'episode.$seriesId.$episodeId.$language';

  bool matchesItem(BazarrWantedItem item) => kind == BazarrSubtitleKind.movie
      ? item.isMovie && item.radarrId == radarrId
      : !item.isMovie &&
            item.seriesId == seriesId &&
            item.episodeId == episodeId;

  bool matchesLanguage(String value) => _sameLanguage(value, language);

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'kind': kind.name,
    'language': language,
    'radarrId': ?radarrId,
    'seriesId': ?seriesId,
    'episodeId': ?episodeId,
  };

  static bool _sameLanguage(String left, String right) {
    final normalizedLeft = BazarrMissingLanguage.normalizeCode(left);
    final normalizedRight = BazarrMissingLanguage.normalizeCode(right);
    return normalizedLeft == normalizedRight ||
        normalizedLeft.split('-').first == normalizedRight.split('-').first;
  }
}

/// Per-provider-account route budget. Reservations are never released because
/// a timed-out request may have consumed the provider's quota.
final class BazarrSubtitleRequestBudget {
  BazarrSubtitleRequestBudget({this.maximum = 5}) {
    if (maximum < 1 || maximum > 20) {
      throw ArgumentError.value(maximum, 'maximum');
    }
  }

  final int maximum;
  final Set<String> _reserved = {};

  int get remaining => maximum - _reserved.length;

  bool wasReserved(BazarrSubtitleRequest request) =>
      _reserved.contains(request.key);

  bool reserve(BazarrSubtitleRequest request) {
    if (_reserved.length >= maximum || _reserved.contains(request.key)) {
      return false;
    }
    _reserved.add(request.key);
    return true;
  }
}
