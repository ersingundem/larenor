/// A search result from Sonarr's `/series/lookup` or Radarr's
/// `/movie/lookup`. Keeps the full [raw] JSON alongside the display
/// fields because adding an item POSTs that same object back with a few
/// fields merged in (network/images/seasons etc. all come along for free)
/// — the standard pattern every *arr client uses.
class ArrLookupResult {
  const ArrLookupResult({
    required this.title,
    required this.remoteId,
    required this.raw,
    this.year,
    this.overview,
    this.posterUrl,
    this.alreadyAdded = false,
  });

  final String title;

  /// `tvdbId`/`tmdbId` (Sonarr/Radarr) are numeric; `foreignArtistId`/
  /// `foreignAuthorId` (Lidarr/Readarr) are MusicBrainz/Goodreads-style
  /// string ids — so this is left untyped rather than forced to `int`.
  final Object? remoteId;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final bool alreadyAdded;
  final Map<String, dynamic> raw;

  factory ArrLookupResult.fromJson(
    Map<String, dynamic> json, {
    required String idFieldName,
  }) {
    final images = json['images'] as List<dynamic>? ?? const [];
    String? poster;
    for (final image in images) {
      final map = image as Map<String, dynamic>;
      if (map['coverType'] == 'poster') {
        poster = (map['remoteUrl'] ?? map['url']) as String?;
        break;
      }
    }

    return ArrLookupResult(
      title: json['title'] as String? ?? 'Unknown',
      remoteId: json[idFieldName] ?? 0,
      year: json['year'] as int?,
      overview: json['overview'] as String?,
      posterUrl: poster,
      alreadyAdded: (json['id'] as int? ?? 0) > 0,
      raw: json,
    );
  }
}
