import 'package:freezed_annotation/freezed_annotation.dart';

part 'ha_registry_entry.freezed.dart';
part 'ha_registry_entry.g.dart';

@freezed
abstract class HaRegistryEntry with _$HaRegistryEntry {
  const factory HaRegistryEntry({
    @JsonKey(name: 'entity_id') required String entityId,
    @JsonKey(name: 'unique_id') String? uniqueId,
    String? platform,
    @JsonKey(name: 'device_id') String? deviceId,
    @JsonKey(name: 'area_id') String? areaId,
    @JsonKey(name: 'disabled_by') String? disabledBy,
    String? name,
    String? icon,
    @JsonKey(name: 'hidden_by') String? hiddenBy,
    @JsonKey(name: 'original_name') String? originalName,
  }) = _HaRegistryEntry;

  const HaRegistryEntry._();

  factory HaRegistryEntry.fromJson(Map<String, dynamic> json) =>
      _$HaRegistryEntryFromJson(json);

  String get displayName => name ?? originalName ?? entityId;
}
