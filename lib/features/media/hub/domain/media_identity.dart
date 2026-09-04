enum MediaKind { movie, tv }

/// The external ids that let the same title be recognised across
/// Jellyfin, Jellyseerr, Sonarr and Radarr.
///
/// TMDB is the primary key: Jellyseerr is TMDB-native, Radarr keys on
/// `tmdbId`, Sonarr's series resource carries one alongside `tvdbId`, and
/// Jellyfin exposes all three through `ProviderIds`. TVDB and IMDb are
/// kept as fallbacks because older Sonarr libraries and some Jellyfin
/// metadata providers fill in only one of them.
class MediaIdentity {
  const MediaIdentity({
    required this.kind,
    this.tmdbId,
    this.tvdbId,
    this.imdbId,
  });

  final MediaKind kind;
  final int? tmdbId;
  final int? tvdbId;
  final String? imdbId;

  bool get isEmpty => tmdbId == null && tvdbId == null && imdbId == null;

  /// Stable key for deduping and map lookups. Prefers TMDB so that two
  /// records describing the same title collapse onto one entry whenever
  /// both know its TMDB id.
  String get key {
    if (tmdbId != null) return '${kind.name}:tmdb:$tmdbId';
    if (tvdbId != null) return '${kind.name}:tvdb:$tvdbId';
    if (imdbId != null) return '${kind.name}:imdb:$imdbId';
    return '${kind.name}:none';
  }

  /// Every key this identity could be indexed under. A record that knows
  /// only a TVDB id and one that knows only a TMDB id can't be matched
  /// directly, so the index stores each identity under all of its known
  /// ids and a lookup tries all of the query's.
  List<String> get allKeys => [
    if (tmdbId != null) '${kind.name}:tmdb:$tmdbId',
    if (tvdbId != null) '${kind.name}:tvdb:$tvdbId',
    if (imdbId != null) '${kind.name}:imdb:$imdbId',
  ];

  /// True when the two records describe the same title — i.e. they're the
  /// same kind and agree on at least one id they both know.
  bool matches(MediaIdentity other) {
    if (kind != other.kind) return false;
    if (tmdbId != null && other.tmdbId != null) return tmdbId == other.tmdbId;
    if (tvdbId != null && other.tvdbId != null) return tvdbId == other.tvdbId;
    if (imdbId != null && other.imdbId != null) return imdbId == other.imdbId;
    return false;
  }

  /// Combines what two records know about the same title, so an identity
  /// resolved from several services ends up carrying every id.
  MediaIdentity mergedWith(MediaIdentity other) => MediaIdentity(
    kind: kind,
    tmdbId: tmdbId ?? other.tmdbId,
    tvdbId: tvdbId ?? other.tvdbId,
    imdbId: imdbId ?? other.imdbId,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaIdentity &&
      other.kind == kind &&
      other.tmdbId == tmdbId &&
      other.tvdbId == tvdbId &&
      other.imdbId == imdbId;

  @override
  int get hashCode => Object.hash(kind, tmdbId, tvdbId, imdbId);

  @override
  String toString() => 'MediaIdentity($key)';
}
