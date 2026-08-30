import 'package:freezed_annotation/freezed_annotation.dart';

part 'ha_entity.freezed.dart';
part 'ha_entity.g.dart';

@freezed
abstract class HaEntity with _$HaEntity {
  const factory HaEntity({
    @JsonKey(name: 'entity_id') required String entityId,
    required String state,
    @Default({}) Map<String, dynamic> attributes,
    @JsonKey(name: 'last_changed') DateTime? lastChanged,
    @JsonKey(name: 'last_updated') DateTime? lastUpdated,
  }) = _HaEntity;

  const HaEntity._();

  factory HaEntity.fromJson(Map<String, dynamic> json) =>
      _$HaEntityFromJson(json);

  String get domain => entityId.split('.').first;

  String get friendlyName =>
      (attributes['friendly_name'] as String?) ?? entityId;

  bool get isOn => state == 'on';

  bool get isToggleable => const {
    'light',
    'switch',
    'input_boolean',
    'fan',
  }.contains(domain);
}
