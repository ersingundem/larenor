import 'package:freezed_annotation/freezed_annotation.dart';

part 'config_entry.freezed.dart';
part 'config_entry.g.dart';

@freezed
abstract class ConfigEntry with _$ConfigEntry {
  const factory ConfigEntry({
    @JsonKey(name: 'entry_id') required String entryId,
    required String domain,
    required String title,
    required String source,
    required String state,
    @JsonKey(name: 'disabled_by') String? disabledBy,
    String? reason,
    @JsonKey(name: 'supports_options') @Default(false) bool supportsOptions,
    @JsonKey(name: 'supports_reconfigure')
    @Default(false)
    bool supportsReconfigure,
  }) = _ConfigEntry;

  factory ConfigEntry.fromJson(Map<String, dynamic> json) =>
      _$ConfigEntryFromJson(json);
}
