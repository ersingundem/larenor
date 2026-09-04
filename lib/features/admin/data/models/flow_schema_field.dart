import 'dart:convert';

enum FlowFieldKind {
  text,
  integer,
  number,
  boolean,
  select,
  entity,
  device,
  area,
  rawFallback,
}

class FlowSelectOption {
  const FlowSelectOption({required this.value, required this.label});
  final dynamic value;
  final String label;
}

/// Distinguishes text being edited as JSON from an already typed HA value.
/// A plain String from a schema default or a service payload stays a String.
class RawFlowJsonInput {
  const RawFlowJsonInput(this.text);
  final String text;
}

/// Shared schema adapter for HA config flows and service fields. Unknown
/// selectors remain editable as validated JSON rather than silently becoming
/// strings, which changes the meaning of object/list parameters.
class FlowSchemaField {
  const FlowSchemaField({
    required this.name,
    required this.required,
    required this.kind,
    this.defaultValue,
    this.options = const [],
    this.multiple = false,
    this.customValue = false,
    this.obscure = false,
    this.multiline = false,
    this.min,
    this.max,
    this.selectorConfig = const {},
  });

  final String name;
  final bool required;
  final FlowFieldKind kind;
  final dynamic defaultValue;
  final List<FlowSelectOption> options;
  final bool multiple;
  final bool customValue;
  final bool obscure;
  final bool multiline;
  final num? min;
  final num? max;
  final Map<String, dynamic> selectorConfig;

  factory FlowSchemaField.fromJson(Map<String, dynamic> json) {
    final selector = _map(json['selector']);
    final key = selector?.keys.firstOrNull ?? json['type']?.toString();
    final config = _map(selector?[key]) ?? const <String, dynamic>{};
    final description = _map(json['description']);
    final kind = switch (key) {
      'text' ||
      'string' ||
      'time' ||
      'date' ||
      'datetime' ||
      'template' ||
      'icon' => FlowFieldKind.text,
      'integer' => FlowFieldKind.integer,
      'float' || 'number' => FlowFieldKind.number,
      'boolean' => FlowFieldKind.boolean,
      'select' || 'multi_select' => FlowFieldKind.select,
      'entity' => FlowFieldKind.entity,
      'device' => FlowFieldKind.device,
      'area' => FlowFieldKind.area,
      _ => FlowFieldKind.rawFallback,
    };
    final name = json['name']?.toString() ?? '';
    return FlowSchemaField(
      name: name,
      required: json['required'] == true,
      kind: kind,
      defaultValue: json.containsKey('default')
          ? json['default']
          : description?['suggested_value'],
      options: _parseOptions(config['options'] ?? json['options']),
      multiple: config['multiple'] == true || key == 'multi_select',
      customValue: config['custom_value'] == true,
      obscure:
          config['type'] == 'password' ||
          name.toLowerCase().contains('password'),
      multiline:
          config['multiline'] == true ||
          key == 'template' ||
          kind == FlowFieldKind.rawFallback,
      min: (config['min'] ?? json['valueMin']) as num?,
      max: (config['max'] ?? json['valueMax']) as num?,
      selectorConfig: config,
    );
  }

  dynamic parseValue(dynamic raw) {
    if (raw is RawFlowJsonInput) {
      if (raw.text.trim().isEmpty) return null;
      return jsonDecode(raw.text);
    }
    if (raw == null ||
        (raw is String &&
            raw.trim().isEmpty &&
            kind != FlowFieldKind.text &&
            kind != FlowFieldKind.rawFallback)) {
      return null;
    }
    if (kind == FlowFieldKind.integer) {
      if (raw is int) return raw;
      return int.parse('$raw');
    }
    if (kind == FlowFieldKind.number) {
      final value = raw is num ? raw : num.parse('$raw');
      if (!value.isFinite) throw const FormatException('Invalid number');
      return value;
    }
    return raw;
  }

  /// Codes are deliberately locale-independent for both flow and action UIs.
  String? validateValue(dynamic raw) {
    final dynamic value;
    try {
      value = parseValue(raw);
    } catch (_) {
      return 'invalid';
    }
    if (value == null || value == '' || value is List && value.isEmpty) {
      return required ? 'required' : null;
    }
    if (kind == FlowFieldKind.boolean && value is! bool) return 'invalid';
    if (kind == FlowFieldKind.text && value is! String) return 'invalid';
    if (value is num &&
        (min != null && value < min! || max != null && value > max!)) {
      return 'invalid';
    }
    if (multiple && kind != FlowFieldKind.rawFallback && value is! List) {
      return 'invalid';
    }
    if (kind == FlowFieldKind.select && !customValue) {
      final values = multiple ? value as List : [value];
      if (values.any(
        (item) => !options.any((option) => option.value == item),
      )) {
        return 'invalid';
      }
    }
    return null;
  }

  /// The common entity filters emitted by HA's modern and legacy selectors.
  /// Compound device/area filters are still validated by the server.
  bool matchesEntity(
    String entityId, {
    String? integration,
    Map<String, dynamic> attributes = const {},
  }) {
    final included = selectorConfig['include_entities'];
    final excluded = selectorConfig['exclude_entities'];
    if (included is List && !included.contains(entityId)) return false;
    if (excluded is List && excluded.contains(entityId)) return false;
    final raw = selectorConfig['filter'];
    final filters = raw is List ? raw : [raw ?? selectorConfig];
    return filters.isEmpty ||
        filters.any((rawFilter) {
          final filter = _map(rawFilter) ?? const <String, dynamic>{};
          bool matches(dynamic expected, dynamic actual) =>
              expected == null ||
              (expected is List
                  ? expected.contains(actual)
                  : expected == actual);
          final supported = attributes['supported_features'] as num? ?? 0;
          final features = filter['supported_features'];
          final requiredFeatures = features is List ? features : [features];
          return matches(filter['domain'], entityId.split('.').first) &&
              matches(filter['integration'], integration) &&
              matches(filter['device_class'], attributes['device_class']) &&
              matches(
                filter['unit_of_measurement'],
                attributes['unit_of_measurement'],
              ) &&
              requiredFeatures.any(
                (bits) =>
                    bits == null ||
                    bits is num &&
                        (supported.toInt() & bits.toInt()) == bits.toInt(),
              );
        });
  }

  static Map<String, dynamic>? _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  static List<FlowSelectOption> _parseOptions(dynamic raw) {
    if (raw is Map) {
      return raw.entries
          .map(
            (entry) =>
                FlowSelectOption(value: entry.key, label: '${entry.value}'),
          )
          .toList();
    }
    if (raw is! List) return const [];
    return raw.map((option) {
      if (option is Map) {
        return FlowSelectOption(
          value: option['value'],
          label: '${option['label'] ?? option['value']}',
        );
      }
      if (option is List && option.length >= 2) {
        return FlowSelectOption(value: option[0], label: '${option[1]}');
      }
      return FlowSelectOption(value: option, label: '$option');
    }).toList();
  }
}

Map<String, dynamic> normalizeFlowValues(
  List<FlowSchemaField> fields,
  Map<String, dynamic> edited,
) {
  final result = <String, dynamic>{};
  for (final field in fields) {
    final value = edited.containsKey(field.name)
        ? edited[field.name]
        : field.defaultValue ??
              (field.required && field.kind == FlowFieldKind.boolean
                  ? false
                  : null);
    final error = field.validateValue(value);
    if (error != null) throw FormatException('${field.name}: $error');
    final parsed = field.parseValue(value);
    if (parsed != null || edited.containsKey(field.name)) {
      result[field.name] = parsed;
    }
  }
  return result;
}
