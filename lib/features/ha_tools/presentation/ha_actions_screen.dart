import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../admin/data/models/flow_schema_field.dart';
import '../../admin/presentation/widgets/dynamic_form_field.dart';
import '../../dashboard/presentation/entity_multi_picker_screen.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../domain/ha_action.dart';
import 'ha_tool_widgets.dart';

final haActionsProvider = FutureProvider.autoDispose<List<HaAction>>((
  ref,
) async {
  final client = ref.watch(haRestClientProvider);
  if (client == null) return [];
  return HaAction.parseCatalog(await client.getServices());
});

class HaActionsScreen extends ConsumerStatefulWidget {
  const HaActionsScreen({super.key, this.entityId});

  /// When opened from an accessory, constrain actions and their target to it.
  final String? entityId;
  @override
  ConsumerState<HaActionsScreen> createState() => _HaActionsScreenState();
}

class _HaActionsScreenState extends ConsumerState<HaActionsScreen> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ServiceRootScaffold(
      title: l10n.haActions,
      slivers: [
        CupertinoSliverRefreshControl(
          onRefresh: () async {
            ref.invalidate(haActionsProvider);
            await ref.read(haActionsProvider.future);
          },
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.entityId ?? l10n.haActionsHint,
                  style: AppText.subhead.copyWith(
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 16),
                CupertinoSearchTextField(
                  placeholder: l10n.haSearchActions,
                  onChanged: (value) =>
                      setState(() => _query = value.toLowerCase().trim()),
                ),
              ],
            ),
          ),
        ),
        ...ref
            .watch(haActionsProvider)
            .when(
              loading: () => [
                const SliverFilledMessage(child: CupertinoActivityIndicator()),
              ],
              error: (error, _) => [
                SliverFilledMessage(
                  child: HaResult(value: '$error', isError: true),
                ),
              ],
              data: (actions) {
                final domain = widget.entityId?.split('.').first;
                final visible = actions
                    .where(
                      (a) =>
                          (domain == null ||
                              ((a.supportsTarget ||
                                      a.fieldMetadata.containsKey(
                                        'entity_id',
                                      )) &&
                                  (a.domain == domain ||
                                      a.domain == 'homeassistant'))) &&
                          '${a.id} ${a.name} ${a.description}'
                              .toLowerCase()
                              .contains(_query),
                    )
                    .toList();
                if (visible.isEmpty) {
                  return [SliverFilledMessage(child: Text(l10n.haNoActions))];
                }
                return [
                  SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final action = visible[index];
                      return CupertinoListTile(
                        leading: const Icon(CupertinoIcons.bolt),
                        title: Text(action.name),
                        subtitle: Text(action.id),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () => Navigator.of(context).push(
                          CupertinoPageRoute(
                            builder: (_) => HaActionScreen(
                              action: action,
                              entityId: widget.entityId,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ];
              },
            ),
      ],
    );
  }
}

class HaActionScreen extends ConsumerStatefulWidget {
  const HaActionScreen({super.key, required this.action, this.entityId});
  final HaAction action;
  final String? entityId;
  @override
  ConsumerState<HaActionScreen> createState() => _HaActionScreenState();
}

class _HaActionScreenState extends ConsumerState<HaActionScreen> {
  final _values = <String, dynamic>{};
  final _target = TextEditingController(text: '{}');
  final _advanced = TextEditingController(text: '{}');
  bool _busy = false;
  bool _returnResponse = false;
  bool _error = false;
  Object? _result;
  @override
  void initState() {
    super.initState();
    _returnResponse = widget.action.requiresResponse;
    if (widget.entityId != null) {
      _target.text = jsonEncode({'entity_id': widget.entityId});
    }
  }

  @override
  void dispose() {
    _target.dispose();
    _advanced.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final action = widget.action;
    if (action.supportsTarget && widget.entityId == null) {
      ref.watch(entitiesProvider);
    }
    return ServiceRootScaffold(
      title: action.name,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '${action.id}\n${action.description}',
              style: AppText.subhead,
            ),
          ),
        ),
        if (action.fields.isNotEmpty)
          SliverToBoxAdapter(
            child: AbsorbPointer(
              absorbing: _busy,
              child: CupertinoFormSection.insetGrouped(
                header: Text(l10n.haServiceData),
                children: [
                  for (final field in action.fields)
                    DynamicFormField(
                      field: field,
                      value: _values[field.name],
                      label:
                          action.fieldMetadata[field.name]?['name'] as String?,
                      description:
                          action.fieldMetadata[field.name]?['description']
                              as String?,
                      onChanged: _busy
                          ? (_) {}
                          : (value) =>
                                setState(() => _values[field.name] = value),
                    ),
                ],
              ),
            ),
          ),
        if (action.supportsTarget || widget.entityId != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HaTextInput(
                    label: l10n.haTarget,
                    controller: _target,
                    lines: 3,
                    readOnly: widget.entityId != null || _busy,
                  ),
                  if (widget.entityId == null) ...[
                    HaHint(l10n.haTargetHint),
                    CupertinoButton(
                      onPressed: _busy ? null : _chooseEntities,
                      child: Text(l10n.haPickEntities),
                    ),
                  ],
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HaTextInput(
                  label: l10n.haServiceData,
                  controller: _advanced,
                  lines: 4,
                  readOnly: _busy,
                ),
                HaHint(l10n.haServiceDataHint),
                if (action.supportsResponse)
                  CupertinoListTile(
                    title: Text(l10n.haReturnResponse),
                    trailing: CupertinoSwitch(
                      value: _returnResponse,
                      onChanged: action.requiresResponse || _busy
                          ? null
                          : (value) => setState(() => _returnResponse = value),
                    ),
                  ),
                const SizedBox(height: 16),
                CupertinoButton.filled(
                  onPressed: _busy ? null : _run,
                  child: _busy
                      ? const CupertinoActivityIndicator()
                      : Text(l10n.haRun),
                ),
                if (_result != null) HaResult(value: _result, isError: _error),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _chooseEntities() async {
    setState(() => _busy = true);
    try {
      final entities = (await ref.read(entitiesProvider.future)).values
          .toList();
      if (!mounted) return;
      Map<String, dynamic> target;
      try {
        target = parseJsonObject(_target.text);
      } on FormatException {
        target = {};
      }
      final ids = target['entity_id'];
      final initial = ids is String
          ? [ids]
          : ids is List
          ? ids.whereType<String>().toList()
          : <String>[];
      final picked = await Navigator.of(context).push<List<String>>(
        CupertinoPageRoute(
          builder: (_) => EntityMultiPickerScreen(
            entities: entities,
            initialEntityIds: initial,
            title: AppLocalizations.of(context).haPickEntities,
          ),
        ),
      );
      if (!mounted || picked == null) return;
      _target.text = jsonEncode({...target, 'entity_id': picked});
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _result = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run() async {
    final l10n = AppLocalizations.of(context);
    final client = ref.read(haRestClientProvider);
    if (client == null) {
      setState(() {
        _error = true;
        _result = l10n.haDisconnected;
      });
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
      _error = false;
    });
    try {
      final extra = parseJsonObject(_advanced.text);
      // Advanced JSON can supply required complex fields. Validate the final
      // field values, preserving additional keys unknown to the current schema.
      final merged = {..._values, ...extra};
      final values = {
        ...extra,
        ...normalizeFlowValues(widget.action.fields, merged),
      };
      if (widget.entityId != null) {
        for (final key in [
          'entity_id',
          'device_id',
          'area_id',
          'floor_id',
          'label_id',
        ]) {
          values.remove(key);
        }
      }
      final target = widget.entityId != null
          ? <String, dynamic>{'entity_id': widget.entityId}
          : parseJsonObject(_target.text);
      if (!mounted) return;
      if (!await confirmHaAction(context, widget.action.id)) return;
      final result = await client.callServiceWithResponse(
        widget.action.domain,
        widget.action.service,
        serviceData: values,
        target: target,
        returnResponse: _returnResponse,
      );
      if (mounted) setState(() => _result = result ?? l10n.haSuccess);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _result = error is FormatException
              ? '${l10n.adminInvalidValue}\n${error.message}'
              : '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
