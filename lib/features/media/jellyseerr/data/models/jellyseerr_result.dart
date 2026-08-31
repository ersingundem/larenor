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
  const factory JellyseerrMediaInfo({int? status}) = _JellyseerrMediaInfo;

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
    String? overview,
    @JsonKey(name: 'mediaInfo') JellyseerrMediaInfo? mediaInfo,
  }) = _JellyseerrResult;

  const JellyseerrResult._();

  factory JellyseerrResult.fromJson(Map<String, dynamic> json) =>
      _$JellyseerrResultFromJson(json);

  String get displayTitle => title ?? name ?? 'Unknown';

  bool get isTv => mediaType == 'tv';

  JellyseerrMediaStatus get status =>
      mediaInfo?.resolvedStatus ?? JellyseerrMediaStatus.unknown;
}
