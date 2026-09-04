import 'dart:convert';

import '../../admin/data/models/flow_schema_field.dart';

/// Action descriptions are discovered from the connected server. Sections
/// organize fields visually; their values still belong at the payload root.
class HaAction {
  const HaAction({
    required this.domain,
    required this.service,
    required this.metadata,
  });
  final String domain;
  final String service;
  final Map<String, dynamic> metadata;
  String get id => '$domain.$service';
  String get name =>
      metadata['name'] as String? ?? service.replaceAll('_', ' ');
  String get description => metadata['description'] as String? ?? '';
  bool get supportsTarget => metadata['target'] is Map;
  bool get supportsResponse => metadata['response'] is Map;
  bool get requiresResponse =>
      supportsResponse && (metadata['response'] as Map)['optional'] != true;

  Map<String, Map<String, dynamic>> get fieldMetadata {
    final fields = <String, Map<String, dynamic>>{};
    void collect(dynamic raw) {
      if (raw is! Map) return;
      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final field = Map<String, dynamic>.from(entry.value as Map);
        if (field['fields'] is Map) {
          collect(field['fields']);
        } else {
          fields['${entry.key}'] = field;
        }
      }
    }

    collect(metadata['fields']);
    return fields;
  }

  List<FlowSchemaField> get fields => [
    for (final entry in fieldMetadata.entries)
      FlowSchemaField.fromJson({...entry.value, 'name': entry.key}),
  ];

  static List<HaAction> parseCatalog(List<Map<String, dynamic>> catalog) {
    final actions = <HaAction>[];
    for (final domain in catalog) {
      final name = domain['domain'];
      final services = domain['services'];
      if (name is! String || services is! Map) continue;
      for (final entry in services.entries) {
        if (entry.value is Map) {
          actions.add(
            HaAction(
              domain: name,
              service: '${entry.key}',
              metadata: Map<String, dynamic>.from(entry.value as Map),
            ),
          );
        }
      }
    }
    return actions..sort((a, b) => a.id.compareTo(b.id));
  }
}

Map<String, dynamic> parseJsonObject(String text) {
  if (text.trim().isEmpty) return {};
  final value = jsonDecode(text);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object.');
  }
  return value;
}
