import 'package:freezed_annotation/freezed_annotation.dart';

part 'jellyseerr_request_item.freezed.dart';
part 'jellyseerr_request_item.g.dart';

/// Jellyseerr's numeric *request* status (distinct from media availability
/// status). Current Seerr source also defines 4=failed and 5=completed.
/// Missing/future status is unknown, never assumed pending approval.
enum JellyseerrRequestStatus {
  pendingApproval,
  approved,
  declined,
  failed,
  completed,
  unknown;

  static JellyseerrRequestStatus fromCode(int? code) {
    switch (code) {
      case 1:
        return JellyseerrRequestStatus.pendingApproval;
      case 2:
        return JellyseerrRequestStatus.approved;
      case 3:
        return JellyseerrRequestStatus.declined;
      case 4:
        return JellyseerrRequestStatus.failed;
      case 5:
        return JellyseerrRequestStatus.completed;
      default:
        return JellyseerrRequestStatus.unknown;
    }
  }

  String get label => switch (this) {
    JellyseerrRequestStatus.pendingApproval => 'Pending approval',
    JellyseerrRequestStatus.approved => 'Approved',
    JellyseerrRequestStatus.declined => 'Declined',
    JellyseerrRequestStatus.failed => 'Failed',
    JellyseerrRequestStatus.completed => 'Completed',
    JellyseerrRequestStatus.unknown => 'Unknown',
  };
}

@freezed
abstract class JellyseerrRequestMedia with _$JellyseerrRequestMedia {
  const factory JellyseerrRequestMedia({
    @JsonKey(name: 'tmdbId') int? tmdbId,
    String? title,
    String? name,
  }) = _JellyseerrRequestMedia;

  const JellyseerrRequestMedia._();

  factory JellyseerrRequestMedia.fromJson(Map<String, dynamic> json) =>
      _$JellyseerrRequestMediaFromJson(json);

  String? get displayTitle => title ?? name;
}

@freezed
abstract class JellyseerrRequestItem with _$JellyseerrRequestItem {
  const factory JellyseerrRequestItem({
    required int id,
    @JsonKey(name: 'type') required String mediaType,
    @JsonKey(name: 'status') int? statusCode,
    @JsonKey(name: 'media') JellyseerrRequestMedia? media,
  }) = _JellyseerrRequestItem;

  const JellyseerrRequestItem._();

  factory JellyseerrRequestItem.fromJson(Map<String, dynamic> json) =>
      _$JellyseerrRequestItemFromJson(json);

  JellyseerrRequestStatus get status =>
      JellyseerrRequestStatus.fromCode(statusCode);

  String get displayTitle =>
      media?.displayTitle ??
      '${mediaType == 'tv' ? 'TV show' : 'Movie'} #${media?.tmdbId ?? id}';
}
