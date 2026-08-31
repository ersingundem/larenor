/// How a config-flow schema field should be rendered by the generic form
/// engine. [rawFallback] covers selector/type shapes we don't specifically
/// recognize — HA has dozens of selector kinds (device, entity, media,
/// color, etc.) and reproducing all of them isn't worth it, so those fall
/// back to a plain text field seeded with the JSON-encoded default.
enum FlowFieldKind { text, integer, number, boolean, select, rawFallback }

class FlowSelectOption {
  const FlowSelectOption({required this.value, required this.label});

  final String value;
  final String label;
}

class FlowSchemaField {
  const FlowSchemaField({
    required this.name,
    required this.required,
    required this.kind,
    this.defaultValue,
    this.options = const [],
  });

  final String name;
  final bool required;
  final FlowFieldKind kind;
  final dynamic defaultValue;
  final List<FlowSelectOption> options;

  /// Parses one entry of a config flow's `data_schema` list. HA serializes
  /// fields in two shapes depending on integration age:
  ///  - modern: `{"name": ..., "selector": {"<kind>": {...}}}`
  ///  - legacy: `{"name": ..., "type": "string"|"integer"|"float"|"boolean"}`
  factory FlowSchemaField.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final required = json['required'] as bool? ?? false;
    final defaultValue = json['default'];

    final selector = _asStringMap(json['selector']);
    if (selector != null && selector.isNotEmpty) {
      return FlowSchemaField._fromSelector(
        selectorKey: selector.keys.first,
        selectorValue: _asStringMap(selector.values.first),
        name: name,
        required: required,
        defaultValue: defaultValue,
      );
    }

    return FlowSchemaField._fromLegacyType(
      type: json['type'] as String?,
      name: name,
      required: required,
      defaultValue: defaultValue,
    );
  }

  factory FlowSchemaField._fromSelector({
    required String selectorKey,
    required Map<String, dynamic>? selectorValue,
    required String name,
    required bool required,
    required dynamic defaultValue,
  }) {
    switch (selectorKey) {
      case 'boolean':
        return FlowSchemaField(
          name: name,
          required: required,
          kind: FlowFieldKind.boolean,
          defaultValue: defaultValue,
        );
      case 'number':
        return FlowSchemaField(
          name: name,
          required: required,
          kind: FlowFieldKind.number,
          defaultValue: defaultValue,
        );
      case 'text':
        return FlowSchemaField(
          name: name,
          required: required,
          kind: FlowFieldKind.text,
          defaultValue: defaultValue,
        );
      case 'select':
        return FlowSchemaField(
          name: name,
          required: required,
          kind: FlowFieldKind.select,
          defaultValue: defaultValue,
          options: _parseSelectOptions(selectorValue?['options']),
        );
      default:
        return FlowSchemaField(
          name: name,
          required: required,
          kind: FlowFieldKind.rawFallback,
          defaultValue: defaultValue,
        );
    }
  }

  factory FlowSchemaField._fromLegacyType({
    required String? type,
    required String name,
    required bool required,
    required dynamic defaultValue,
  }) {
    final kind = switch (type) {
      'string' => FlowFieldKind.text,
      'integer' => FlowFieldKind.integer,
      'float' => FlowFieldKind.number,
      'boolean' => FlowFieldKind.boolean,
      _ => FlowFieldKind.rawFallback,
    };
    return FlowSchemaField(
      name: name,
      required: required,
      kind: kind,
      defaultValue: defaultValue,
    );
  }

  /// Converts any `Map` (regardless of its static key/value types, which
  /// can vary between real `jsonDecode` output and Dart map literals) to
  /// `Map<String, dynamic>`, or null if [value] isn't a map at all.
  static Map<String, dynamic>? _asStringMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static List<FlowSelectOption> _parseSelectOptions(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((option) {
      if (option is Map<String, dynamic>) {
        final value = option['value']?.toString() ?? '';
        final label = option['label']?.toString() ?? value;
        return FlowSelectOption(value: value, label: label);
      }
      return FlowSelectOption(
        value: option.toString(),
        label: option.toString(),
      );
    }).toList();
  }
}
