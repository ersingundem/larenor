import 'package:freezed_annotation/freezed_annotation.dart';

part 'jellyseerr_result.freezed.dart';
part 'jellyseerr_result.g.dart';

/// Jellyseerr's numeric media availability status.
/// See Overseerr/Jellyseerr's `MediaStatus` enum (stable across both forks).
enum JellyseerrMediaStatus {
  unknown,
  pending,
  processing,
  partiallyAvailable,
  available;

  static JellyseerrMediaStatus fromCode(int? code) {
    switch (code) {
      case 2:
        return JellyseerrMediaStatus.pending;
      case 3:
        return JellyseerrMediaStatus.processing;
      case 4:
        return JellyseerrMediaStatus.partiallyAvailable;
      case 5:
        return JellyseerrMediaStatus.available;
      default:
        return JellyseerrMediaStatus.unknown;
    }
  }

  String get label => switch (this) {
    JellyseerrMediaStatus.unknown => 'Not requested',
    JellyseerrMediaStatus.pending => 'Pending',
    JellyseerrMediaStatus.processing => 'Processing',
    JellyseerrMediaStatus.partiallyAvailable => 'Partially available',
    JellyseerrMediaStatus.available => 'Available',
  };
}

@freezed
abstract class JellyseerrMediaInfo with _$JellyseerrMediaInfo {
  const factory JellyseerrMediaInfo({
    int? status,
    @JsonKey(name: 'tmdbId') int? tmdbId,
    @JsonKey(name: 'tvdbId') int? tvdbId,

    /// Jellyseerr records the Jellyfin item it matched a title to. That's
    /// a direct bridge — when it's present the hub can jump straight to
    /// playback without resolving through external ids at all.
    @JsonKey(name: 'jellyfinMediaId') String? jellyfinMediaId,
  }) = _JellyseerrMediaInfo;

  const JellyseerrMediaInfo._();

  factory JellyseerrMediaInfo.fromJson(Map<String, dynamic> json) =>
      _$JellyseerrMediaInfoFromJson(json);

  JellyseerrMediaStatus get resolvedStatus =>
      JellyseerrMediaStatus.fromCode(status);
}

@freezed
abstract class JellyseerrResult with _$JellyseerrResult {
  const factory JellyseerrResult({
    required int id,
    @JsonKey(name: 'mediaType') required String mediaType,
    String? title,
    String? name,
    @JsonKey(name: 'posterPath') String? posterPath,
    @JsonKey(name: 'backdropPath') String? backdropPath,
    String? overview,
    @JsonKey(name: 'releaseDate') String? releaseDate,
    @JsonKey(name: 'firstAirDate') String? firstAirDate,
    @JsonKey(name: 'voteAverage') double? voteAverage,
    @JsonKey(name: 'mediaInfo') JellyseerrMediaInfo? mediaInfo,
  }) = _JellyseerrResult;

  const JellyseerrResult._();

  factory JellyseerrResult.fromJson(Map<String, dynamic> json) =>
      _$JellyseerrResultFromJson(json);

  String get displayTitle => title ?? name ?? 'Unknown';

  bool get isTv => mediaType == 'tv';

  /// TMDB ids are what everything else joins on. [id] already is one for
  /// search/discover results, but `mediaInfo` wins when present since
  /// that's Jellyseerr's own resolved value.
  int get tmdbId => mediaInfo?.tmdbId ?? id;

  int? get year {
    final raw = releaseDate ?? firstAirDate;
    if (raw == null || raw.length < 4) return null;
    return int.tryParse(raw.substring(0, 4));
  }

  JellyseerrMediaStatus get status =>
      mediaInfo?.resolvedStatus ?? JellyseerrMediaStatus.unknown;
}
