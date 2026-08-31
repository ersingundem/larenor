import 'package:freezed_annotation/freezed_annotation.dart';

import 'flow_schema_field.dart';

part 'flow_step.freezed.dart';
part 'flow_step.g.dart';

List<FlowSchemaField> _schemaFromJson(List<dynamic>? raw) => (raw ?? const [])
    .map((e) => FlowSchemaField.fromJson(e as Map<String, dynamic>))
    .toList();

@freezed
abstract class FlowStep with _$FlowStep {
  const factory FlowStep({
    @JsonKey(name: 'flow_id') String? flowId,
    required String type,
    @JsonKey(name: 'step_id') String? stepId,
    String? handler,
    String? title,
    String? reason,
    @JsonKey(name: 'last_step') bool? lastStep,
    @JsonKey(name: 'menu_options') List<String>? menuOptions,
    Map<String, dynamic>? errors,
    @JsonKey(
      name: 'data_schema',
      fromJson: _schemaFromJson,
      includeToJson: false,
    )
    @Default([])
    List<FlowSchemaField> dataSchema,
  }) = _FlowStep;

  factory FlowStep.fromJson(Map<String, dynamic> json) =>
      _$FlowStepFromJson(json);
}
