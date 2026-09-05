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
import 'ha_session_guard.dart';
import '../../dashboard/presentation/dashboard_edit_guard.dart';
import '../../../shared/widgets/action_status_indicator.dart';

final haActionsProvider = FutureProvider.autoDispose<List<HaAction>>((
  ref,
) async {
  final client = ref.watch(haRestClientProvider);
  if (client == null) return [];
  return HaAction.parseCatalog(await client.getServices());
}, retry: (_, _) => null);

class HaActionsScreen extends ConsumerStatefulWidget {
  const HaActionsScreen({super.key, this.entityId, this.sourceCurrent});
  final bool Function()? sourceCurrent;

  /// When opened from an accessory, constrain actions and their target to it.
  final String? entityId;
  @override
  ConsumerState<HaActionsScreen> createState() => _HaActionsScreenState();
}

class _HaActionsScreenState extends HaSessionState<HaActionsScreen> {
  String _query = '';
  bool _opening = false;
  Route<void>? _child;
  @override
  bool get ownsRouteCover => _child?.isActive == true;
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;
  @override
  void clearPendingInteraction() {
    _query = '';
    _opening = false;
    final route = _child;
    _child = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void didUpdateWidget(covariant HaActionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entityId != widget.entityId) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  Future<void> _open(HaAction action) async {
    if (_opening) return;
    final lease = captureHaSession(), source = captureHaRouteSource(context);
    if (lease == null || source == null) return;
    final catalogue = ref.read(haActionsProvider);
    if (catalogue.isLoading ||
        catalogue.hasError ||
        !(catalogue.value?.contains(action) ?? false)) {
      return;
    }
    setState(() => _opening = true);
    final upstream = widget.sourceCurrent;
    final route = CupertinoPageRoute<void>(
      builder: (_) => HaActionScreen(
        action: action,
        entityId: widget.entityId,
        sourceCurrent: () => source() && (upstream?.call() ?? true),
      ),
    );
    _child = route;
    try {
      await Navigator.of(context).push(route);
    } finally {
      if (identical(_child, route)) _child = null;
      if (mounted && sessionCurrent(lease.generation)) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchHaSession();
    final l10n = AppLocalizations.of(context);
    if (!haSessionAvailable) {
      return ServiceRootScaffold(
        title: l10n.haActions,
        slivers: [SliverFilledMessage(child: Text(l10n.mediaRemoteExpired))],
      );
    }
    final lease = captureHaSession();
    return ServiceRootScaffold(
      title: l10n.haActions,
      slivers: [
        CupertinoSliverRefreshControl(
          onRefresh: () async {
            if (lease == null || !isHaSessionCurrent(lease)) return;
            ref.invalidate(haActionsProvider);
            try {
              await ref.read(haActionsProvider.future);
            } catch (_) {
              /* Render sanitized catalog error. */
            }
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
                  onChanged: (value) {
                    if (lease != null && isHaSessionCurrent(lease)) {
                      setState(() => _query = value.toLowerCase().trim());
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        ...ref
            .watch(haActionsProvider)
            .when(
              skipLoadingOnRefresh: false,
              skipLoadingOnReload: false,
              skipError: false,
              loading: () => [
                const SliverFilledMessage(child: CupertinoActivityIndicator()),
              ],
              error: (error, _) => [
                SliverFilledMessage(
                  child: HaResult(value: l10n.healthReadError, isError: true),
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
                        onTap: _opening
                            ? null
                            : haCallback(() => _open(action)),
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
  const HaActionScreen({
    super.key,
    required this.action,
    this.entityId,
    this.sourceCurrent,
  });
  final bool Function()? sourceCurrent;
  final HaAction action;
  final String? entityId;
  @override
  ConsumerState<HaActionScreen> createState() => _HaActionScreenState();
}

class _HaActionScreenState extends HaSessionState<HaActionScreen> {
  final _values = <String, dynamic>{};
  final _target = TextEditingController(text: '{}');
  final _advanced = TextEditingController(text: '{}');
  bool _busy = false, _sending = false;
  Route<dynamic>? _modal;
  @override
  bool get ownsRouteCover => _modal is PageRoute && _modal?.isActive == true;
  bool _returnResponse = false;
  bool _error = false;
  Object? _result;
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;
  @override
  void clearPendingInteraction() {
    _values.clear();
    _target.text = widget.entityId == null
        ? '{}'
        : jsonEncode({'entity_id': widget.entityId});
    _advanced.text = '{}';
    _busy = false;
    _sending = false;
    _error = false;
    _result = null;
    final route = _modal;
    _modal = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void didUpdateWidget(covariant HaActionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entityId != widget.entityId ||
        oldWidget.action.id != widget.action.id) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  HaAction? get _currentAction {
    if (!haSessionAvailable) return null;
    final catalog = ref.read(haActionsProvider);
    return catalog.isLoading || catalog.hasError
        ? null
        : catalog.value
              ?.where((action) => action.id == widget.action.id)
              .firstOrNull;
  }

  bool _current(HaSessionLease lease, HaAction action) {
    if (!isHaSessionCurrent(lease)) return false;
    final current = _currentAction;
    if (current == null ||
        current.id != action.id ||
        jsonEncode(current.metadata) != jsonEncode(action.metadata)) {
      return false;
    }
    if (widget.entityId == null) return true;
    final states = ref.read(entitiesProvider);
    return !states.isLoading &&
        !states.hasError &&
        states.value?[widget.entityId] != null;
  }

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
    watchHaSession();
    final l10n = AppLocalizations.of(context);
    if (!haSessionAvailable) {
      return ServiceRootScaffold(
        title: l10n.haActions,
        slivers: [SliverFilledMessage(child: Text(l10n.mediaRemoteExpired))],
      );
    }
    final catalog = ref.watch(haActionsProvider);
    if (widget.entityId != null) ref.watch(entitiesProvider);
    final action = _currentAction;
    if (action == null) {
      return ServiceRootScaffold(
        title: l10n.haActions,
        slivers: [
          SliverFilledMessage(
            child: catalog.isLoading
                ? const CupertinoActivityIndicator()
                : Text(l10n.healthReadError),
          ),
        ],
      );
    }
    ref.watch(haRestClientProvider);
    final lease = captureHaSession();
    final available = lease != null && _current(lease, action);

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
              absorbing: _busy || !available,
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
                      onChanged: (value) {
                        if (!_busy &&
                            lease != null &&
                            _current(lease, action)) {
                          setState(() => _values[field.name] = value);
                        }
                      },
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
                    readOnly: widget.entityId != null || _busy || !available,
                  ),
                  if (widget.entityId == null) ...[
                    HaHint(l10n.haTargetHint),
                    CupertinoButton(
                      onPressed: _busy || !available
                          ? null
                          : haCallback(_chooseEntities),
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
                  readOnly: _busy || !available,
                ),
                HaHint(l10n.haServiceDataHint),
                if (action.supportsResponse)
                  CupertinoListTile(
                    title: Text(l10n.haReturnResponse),
                    trailing: CupertinoSwitch(
                      value: _returnResponse,
                      onChanged: action.requiresResponse || _busy || !available
                          ? null
                          : (value) {
                              if (_current(lease, action)) {
                                setState(() => _returnResponse = value);
                              }
                            },
                    ),
                  ),
                const SizedBox(height: 16),
                CupertinoButton.filled(
                  onPressed: _busy || !available ? null : haCallback(_run),
                  child: _sending
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
    if (_busy) return;
    final lease = captureHaSession();
    final action = _currentAction;
    if (lease == null || action == null) return;
    setState(() => _busy = true);
    try {
      final entities = (await ref.read(entitiesProvider.future)).values
          .toList();
      if (!mounted || !_current(lease, action)) return;
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
      final route = CupertinoPageRoute<List<String>>(
        builder: (_) => EntityMultiPickerScreen(
          entities: entities,
          initialEntityIds: initial,
          title: AppLocalizations.of(context).haPickEntities,
        ),
      );
      _modal = route;
      final picked = await Navigator.of(context).push(route);
      if (identical(_modal, route)) _modal = null;
      if (!_current(lease, action) || picked == null) return;
      final states = ref.read(entitiesProvider);
      if (states.isLoading ||
          states.hasError ||
          picked.any((id) => !states.value!.containsKey(id))) {
        return;
      }
      _target.text = jsonEncode({...target, 'entity_id': picked});
    } catch (_) {
      if (_current(lease, action)) {
        setState(() {
          _error = true;
          _result = AppLocalizations.of(context).healthReadError;
        });
      }
    } finally {
      if (mounted && sessionCurrent(lease.generation)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _run() async {
    if (_busy) return;
    final lease = captureHaSession();
    final action = _currentAction;
    if (lease == null || action == null || !_current(lease, action)) return;
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
      final values = {...extra, ...normalizeFlowValues(action.fields, merged)};
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
      if (!_current(lease, action)) return;
      final response = action.requiresResponse || _returnResponse;
      final route = CupertinoDialogRoute<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(l10n.haConfirmRun),
          content: Text(action.id),
          actions: [
            CupertinoDialogAction(
              onPressed: () => closeDashboardModal(dialogContext, false),
              child: Text(l10n.commonCancel),
            ),
            CupertinoDialogAction(
              onPressed: () => closeDashboardModal(dialogContext, true),
              child: Text(l10n.haRun),
            ),
          ],
        ),
      );
      _modal = route;
      final confirmed = await Navigator.of(context).push(route);
      if (identical(_modal, route)) _modal = null;
      if (confirmed != true ||
          !_current(lease, action) ||
          !identical(client, ref.read(haRestClientProvider))) {
        return;
      }
      setState(() => _sending = true);
      final result = await client.callServiceWithResponse(
        action.domain,
        action.service,
        serviceData: values,
        target: target,
        returnResponse: response,
      );
      if (_current(lease, action)) {
        setState(() => _result = result ?? l10n.actionAccepted);
      }
    } catch (error) {
      if (_current(lease, action)) {
        setState(() {
          _error = true;
          _result = error is FormatException
              ? '${l10n.adminInvalidValue}\n${error.message}'
              : actionErrorLabel(l10n, error);
        });
      }
    } finally {
      if (mounted && sessionCurrent(lease.generation)) {
        setState(() {
          _busy = false;
          _sending = false;
        });
      }
    }
  }
}
