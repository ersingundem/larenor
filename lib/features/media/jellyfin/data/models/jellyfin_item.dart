import 'package:freezed_annotation/freezed_annotation.dart';

part 'jellyfin_item.freezed.dart';
part 'jellyfin_item.g.dart';

enum JellyfinPlaybackEligibility { unknown, unavailable, eligible, container }

@freezed
abstract class JellyfinItem with _$JellyfinItem {
  const factory JellyfinItem({
    @JsonKey(name: 'Id') required String id,
    @JsonKey(name: 'Name') required String name,
    @JsonKey(name: 'Type') required String type,
    @JsonKey(name: 'Overview') String? overview,
    @JsonKey(name: 'ProductionYear') int? productionYear,
    @JsonKey(name: 'SeriesName') String? seriesName,
    @JsonKey(name: 'UserData') JellyfinUserData? userData,

    /// External metadata ids (`Tmdb`, `Imdb`, `Tvdb`, …). Jellyfin only
    /// includes this on list responses when the request asks for
    /// `Fields=ProviderIds`, so [JellyfinClient] does exactly that — it's
    /// what lets a library item be matched to the same title in
    /// Jellyseerr, Radarr or Sonarr.
    @JsonKey(name: 'ProviderIds') Map<String, String>? providerIds,
    @JsonKey(name: 'SeriesId') String? seriesId,
    @JsonKey(name: 'IndexNumber') int? indexNumber,
    @JsonKey(name: 'ParentIndexNumber') int? parentIndexNumber,
    @JsonKey(name: 'RunTimeTicks') int? runTimeTicks,
    @JsonKey(name: 'CommunityRating') double? communityRating,
    @JsonKey(name: 'Genres') List<String>? genres,

    /// Compatibility flags may be returned by older servers/plugins. Current
    /// Jellyfin describes virtual/missing items through LocationType instead.
    @JsonKey(name: 'IsMissing') bool? isMissing,
    @JsonKey(name: 'IsVirtualItem') bool? isVirtualItem,
    @JsonKey(name: 'LocationType') String? locationType,
    @JsonKey(name: 'PlayAccess') String? playAccess,

    /// The server deliberately omits a count of one; null is not zero.
    @JsonKey(name: 'MediaSourceCount') int? mediaSourceCount,
    @JsonKey(name: 'PremiereDate') DateTime? premiereDate,

    /// Per-image-type content hashes. Appending one to an image URL makes
    /// it immutable, so a cached poster is only re-fetched when the
    /// artwork itself actually changes.
    @JsonKey(name: 'ImageTags') Map<String, String>? imageTags,
    @JsonKey(name: 'BackdropImageTags') List<String>? backdropImageTags,
  }) = _JellyfinItem;

  const JellyfinItem._();

  factory JellyfinItem.fromJson(Map<String, dynamic> json) =>
      _$JellyfinItemFromJson(json);

  bool get isVirtual => isVirtualItem == true || locationType == 'Virtual';

  /// Eligible to negotiate playback, based on this account's library metadata.
  /// A Movie/Episode identifier alone is not a media file. PlaybackInfo must
  /// still approve a source for the actual device; file presence/decoding is
  /// not guaranteed by a cached library response.
  bool get isPlayable =>
      playbackEligibility == JellyfinPlaybackEligibility.eligible;

  JellyfinPlaybackEligibility get playbackEligibility {
    if ({'Series', 'Season', 'CollectionFolder', 'Folder'}.contains(type)) {
      return JellyfinPlaybackEligibility.container;
    }
    if ((type != 'Movie' && type != 'Episode') ||
        isMissing == true ||
        isVirtual ||
        locationType == 'Offline' ||
        playAccess == 'None' ||
        (mediaSourceCount != null && mediaSourceCount! <= 0)) {
      return JellyfinPlaybackEligibility.unavailable;
    }
    if ((locationType != 'FileSystem' && locationType != 'Remote') ||
        playAccess != 'Full') {
      return JellyfinPlaybackEligibility.unknown;
    }
    return JellyfinPlaybackEligibility.eligible;
  }

  Duration get resumePosition {
    if (userData?.played == true) return Duration.zero;
    final ticks = userData?.playbackPositionTicks ?? 0;
    if (ticks <= 0) return Duration.zero;
    if (runTimeTicks != null && ticks >= runTimeTicks!) return Duration.zero;
    return Duration(microseconds: ticks ~/ 10);
  }

  double get playedFraction {
    final percentage = userData?.playedPercentage;
    if (percentage != null) return (percentage / 100).clamp(0, 1);
    final runtime = runTimeTicks ?? 0;
    if (runtime <= 0) return 0;
    return ((userData?.playbackPositionTicks ?? 0) / runtime).clamp(0, 1);
  }

  /// Provider id lookups are case-insensitive because Jellyfin plugins
  /// haven't been consistent about casing (`Tmdb` vs `TMDB` vs `tmdb`).
  String? providerId(String provider) {
    final ids = providerIds;
    if (ids == null) return null;
    final wanted = provider.toLowerCase();
    for (final entry in ids.entries) {
      if (entry.key.toLowerCase() == wanted && entry.value.isNotEmpty) {
        return entry.value;
      }
    }
    return null;
  }

  int? get tmdbId => int.tryParse(providerId('Tmdb') ?? '');
  int? get tvdbId => int.tryParse(providerId('Tvdb') ?? '');
  String? get imdbId => providerId('Imdb');

  Duration? get runtime =>
      runTimeTicks == null ? null : Duration(microseconds: runTimeTicks! ~/ 10);
}

@freezed
abstract class JellyfinUserData with _$JellyfinUserData {
  const factory JellyfinUserData({
    @JsonKey(name: 'PlaybackPositionTicks')
    @Default(0)
    int playbackPositionTicks,
    @JsonKey(name: 'PlayedPercentage') double? playedPercentage,
    @JsonKey(name: 'Played') @Default(false) bool played,
  }) = _JellyfinUserData;

  factory JellyfinUserData.fromJson(Map<String, dynamic> json) =>
      _$JellyfinUserDataFromJson(json);
}
