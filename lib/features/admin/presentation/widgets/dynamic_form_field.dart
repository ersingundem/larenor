import 'dart:convert';

import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../data/models/flow_schema_field.dart';
import '../../providers/admin_providers.dart';

/// Shared native HA form field; parent owns the value and submission policy.
class DynamicFormField extends ConsumerWidget {
  const DynamicFormField({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
    this.label,
    this.description,
  });
  final FlowSchemaField field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;
  final String? label;
  final String? description;

  String get _label {
    if (label != null) return label!;
    final text = field.name.replaceAll('_', ' ');
    return text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = _buildRow(context, ref);
    return description == null
        ? row
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  description!,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ],
          );
  }

  Widget _buildRow(BuildContext context, WidgetRef ref) {
    if (field.kind == FlowFieldKind.boolean) {
      return CupertinoListTile(
        title: Text(_label),
        trailing: CupertinoSwitch(
          value: (value ?? field.defaultValue) == true,
          onChanged: onChanged,
        ),
      );
    }
    if ([
      FlowFieldKind.select,
      FlowFieldKind.entity,
      FlowFieldKind.device,
      FlowFieldKind.area,
    ].contains(field.kind)) {
      var options = field.options;
      var loading = false;
      Object? error;
      switch (field.kind) {
        case FlowFieldKind.entity:
          final registry = ref.watch(entityRegistryProvider);
          final states = ref.watch(entitiesProvider).value;
          loading = registry.isLoading;
          error = registry.error;
          options = (registry.value ?? [])
              .where((entity) {
                return field.matchesEntity(
                  entity.entityId,
                  integration: entity.platform,
                  attributes: states?[entity.entityId]?.attributes ?? const {},
                );
              })
              .map(
                (entity) => FlowSelectOption(
                  value: entity.entityId,
                  label: '${entity.displayName} (${entity.entityId})',
                ),
              )
              .toList();
        case FlowFieldKind.device:
          final devices = ref.watch(devicesProvider);
          loading = devices.isLoading;
          error = devices.error;
          options = (devices.value ?? [])
              .map(
                (device) => FlowSelectOption(
                  value: device.id,
                  label: device.displayName,
                ),
              )
              .toList();
        case FlowFieldKind.area:
          final areas = ref.watch(areasProvider);
          loading = areas.isLoading;
          error = areas.error;
          options = (areas.value ?? [])
              .map(
                (area) =>
                    FlowSelectOption(value: area.areaId, label: area.name),
              )
              .toList();
        default:
          break;
      }
      if (error != null || field.customValue) return _textField(context);
      final current = value ?? field.defaultValue;
      final values = current is List
          ? current
          : current == null
          ? []
          : [current];
      final selected = values
          .map(
            (item) =>
                options
                    .where((option) => option.value == item)
                    .firstOrNull
                    ?.label ??
                '$item',
          )
          .join(', ');
      return CupertinoListTile(
        title: Text(_label),
        additionalInfo: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(
            selected.isEmpty
                ? AppLocalizations.of(context).dynamicFormSelect
                : selected,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: loading
            ? const CupertinoActivityIndicator()
            : const CupertinoListTileChevron(),
        onTap: loading ? null : () => _pick(context, options, values),
      );
    }
    return _textField(context);
  }

  Widget _textField(BuildContext context) => CupertinoTextFormFieldRow(
    prefix: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Text(_label),
    ),
    placeholder: field.kind == FlowFieldKind.rawFallback || field.multiple
        ? 'JSON'
        : field.required
        ? AppLocalizations.of(context).dynamicFormRequired
        : AppLocalizations.of(context).dynamicFormOptional,
    initialValue: _initialValue(),
    obscureText: field.obscure,
    autocorrect: !field.obscure,
    maxLines: field.obscure
        ? 1
        : field.multiline
        ? 5
        : 1,
    keyboardType:
        [FlowFieldKind.integer, FlowFieldKind.number].contains(field.kind)
        ? const TextInputType.numberWithOptions(decimal: true, signed: true)
        : TextInputType.text,
    onChanged: (text) {
      if (field.multiple && field.kind != FlowFieldKind.rawFallback) {
        try {
          onChanged(jsonDecode(text));
        } catch (_) {
          onChanged(text);
        }
      } else if (field.kind == FlowFieldKind.rawFallback) {
        onChanged(RawFlowJsonInput(text));
      } else {
        onChanged(text);
      }
    },
  );

  String _initialValue() {
    final current = value ?? field.defaultValue;
    if (current == null) return '';
    if (current is RawFlowJsonInput) return current.text;
    if (current is String && field.kind != FlowFieldKind.rawFallback) {
      return current;
    }
    return jsonEncode(current);
  }

  Future<void> _pick(
    BuildContext context,
    List<FlowSelectOption> options,
    List<dynamic> current,
  ) async {
    final result = await Navigator.of(context).push<List<dynamic>>(
      CupertinoPageRoute(
        builder: (_) => _SelectionScreen(
          title: _label,
          options: options,
          selected: current,
          multiple: field.multiple,
        ),
      ),
    );
    if (result != null) onChanged(field.multiple ? result : result.firstOrNull);
  }
}

class _SelectionScreen extends StatefulWidget {
  const _SelectionScreen({
    required this.title,
    required this.options,
    required this.selected,
    required this.multiple,
  });
  final String title;
  final List<FlowSelectOption> options;
  final List<dynamic> selected;
  final bool multiple;
  @override
  State<_SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<_SelectionScreen> {
  late final _selected = [...widget.selected];
  String _query = '';
  @override
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(widget.title),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => Navigator.pop(context, _selected),
        child: Text(AppLocalizations.of(context).commonDone),
      ),
    ),
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: CupertinoSearchTextField(
              onChanged: (value) =>
                  setState(() => _query = value.toLowerCase()),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final option in widget.options.where(
                  (option) => option.label.toLowerCase().contains(_query),
                ))
                  CupertinoListTile(
                    title: Text(option.label),
                    trailing: _selected.contains(option.value)
                        ? const Icon(CupertinoIcons.check_mark)
                        : null,
                    onTap: () {
                      if (!widget.multiple) {
                        Navigator.pop(context, [option.value]);
                        return;
                      }
                      setState(() {
                        _selected.contains(option.value)
                            ? _selected.remove(option.value)
                            : _selected.add(option.value);
                      });
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
