import 'package:freezed_annotation/freezed_annotation.dart';

part 'ha_device.freezed.dart';
part 'ha_device.g.dart';

@freezed
abstract class HaDevice with _$HaDevice {
  const factory HaDevice({
    required String id,
    String? name,
    String? manufacturer,
    String? model,
    @JsonKey(name: 'area_id') String? areaId,
    @JsonKey(name: 'config_entry_id') String? configEntryId,
    @JsonKey(name: 'disabled_by') String? disabledBy,
    @JsonKey(name: 'name_by_user') String? nameByUser,
  }) = _HaDevice;

  const HaDevice._();

  factory HaDevice.fromJson(Map<String, dynamic> json) =>
      _$HaDeviceFromJson(json);

  String get displayName => nameByUser ?? name ?? id;
}
