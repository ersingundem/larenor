import 'package:freezed_annotation/freezed_annotation.dart';

part 'jellyfin_item.freezed.dart';
part 'jellyfin_item.g.dart';

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
  }) = _JellyfinItem;

  const JellyfinItem._();

  factory JellyfinItem.fromJson(Map<String, dynamic> json) =>
      _$JellyfinItemFromJson(json);

  bool get isPlayable => type == 'Movie' || type == 'Episode';

  double get playedFraction => (userData?.playedPercentage ?? 0) / 100;
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
