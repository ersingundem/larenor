import 'package:freezed_annotation/freezed_annotation.dart';

part 'ha_area.freezed.dart';
part 'ha_area.g.dart';

@freezed
abstract class HaArea with _$HaArea {
  const factory HaArea({
    @JsonKey(name: 'area_id') required String areaId,
    required String name,
    String? picture,
  }) = _HaArea;

  factory HaArea.fromJson(Map<String, dynamic> json) => _$HaAreaFromJson(json);
}
