import 'dart:convert';

import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../data/models/flow_schema_field.dart';

/// Renders one field of a config-flow `data_schema` as a Cupertino form
/// row, resolving how based on [FlowSchemaField.kind]. Fully controlled:
/// the parent screen owns the current value and receives changes via
/// [onChanged] rather than this widget holding its own source of truth.
class DynamicFormField extends StatelessWidget {
  const DynamicFormField({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
  });

  final FlowSchemaField field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  String get _label {
    final withSpaces = field.name.replaceAll('_', ' ');
    if (withSpaces.isEmpty) return withSpaces;
    return withSpaces[0].toUpperCase() + withSpaces.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    switch (field.kind) {
      case FlowFieldKind.boolean:
        return CupertinoListTile(
          title: Text(_label),
          trailing: CupertinoSwitch(
            value: (value as bool?) ?? (field.defaultValue as bool?) ?? false,
            onChanged: onChanged,
          ),
        );

      case FlowFieldKind.select:
        return CupertinoListTile(
          title: Text(_label),
          additionalInfo: Text(_currentSelectLabel(context)),
          trailing: const CupertinoListTileChevron(),
          onTap: () => _showPicker(context),
        );

      case FlowFieldKind.integer:
      case FlowFieldKind.number:
        return CupertinoTextFormFieldRow(
          prefix: Text(_label),
          placeholder: field.required
              ? AppLocalizations.of(context).dynamicFormRequired
              : AppLocalizations.of(context).dynamicFormOptional,
          keyboardType: TextInputType.numberWithOptions(
            decimal: field.kind == FlowFieldKind.number,
          ),
          initialValue: (value ?? field.defaultValue)?.toString() ?? '',
          onChanged: (text) => onChanged(
            field.kind == FlowFieldKind.integer
                ? int.tryParse(text)
                : double.tryParse(text),
          ),
        );

      case FlowFieldKind.text:
      case FlowFieldKind.rawFallback:
        return CupertinoTextFormFieldRow(
          prefix: Text(_label),
          placeholder: field.required
              ? AppLocalizations.of(context).dynamicFormRequired
              : AppLocalizations.of(context).dynamicFormOptional,
          obscureText: field.name.toLowerCase().contains('password'),
          initialValue: _initialTextValue(),
          onChanged: onChanged,
        );
    }
  }

  String _initialTextValue() {
    if (value is String) return value as String;
    if (value != null) return jsonEncode(value);
    if (field.defaultValue == null) return '';
    if (field.defaultValue is String) return field.defaultValue as String;
    return jsonEncode(field.defaultValue);
  }

  String _currentSelectLabel(BuildContext context) {
    final current = (value as String?) ?? field.defaultValue?.toString();
    for (final option in field.options) {
      if (option.value == current) return option.label;
    }
    return current ?? AppLocalizations.of(context).dynamicFormSelect;
  }

  Future<void> _showPicker(BuildContext context) async {
    final chosen = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(_label),
        actions: [
          for (final option in field.options)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, option.value),
              child: Text(option.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (chosen != null) onChanged(chosen);
  }
}
