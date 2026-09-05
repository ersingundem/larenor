import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../ha_tools/presentation/ha_session_guard.dart';
import '../../../ha_tools/presentation/ha_actions_screen.dart';
import '../../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../../../health/providers/ha_actions.dart';
import '../../../../shared/widgets/action_status_indicator.dart';
import '../../providers/dashboard_providers.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/settings_section.dart';
import 'entity_controls.dart';

const _hiddenAttributeKeys = {'friendly_name', 'icon'};

/// Shared "more info" popup used by every entity-backed tile — full state,
/// a brightness slider for lights, and a raw attribute dump. Dedicated tile
/// types (media player, climate, weather, camera) get their own bespoke
/// controls instead of relying on this generic sheet.
Future<void> showEntityMoreInfo(BuildContext context, String entityId) {
  final source = captureHaRouteSource(context);
  if (source == null) return Future.value();
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (context) =>
        EntityMoreInfo(entityId: entityId, sourceCurrent: source),
  );
}

class EntityMoreInfo extends ConsumerStatefulWidget {
  const EntityMoreInfo({
    super.key,
    required this.entityId,
    this.asPage = false,
    this.sourceCurrent,
  });

  final bool asPage;
  final bool Function()? sourceCurrent;

  final String entityId;

  @override
  ConsumerState<EntityMoreInfo> createState() => _EntityMoreInfoState();
}

class _EntityMoreInfoState extends HaSessionState<EntityMoreInfo> {
  String get entityId => widget.entityId;
  bool get asPage => widget.asPage;
  bool _favoriteBusy = false, _opening = false;
  String? _error;
  Route<void>? _actionsRoute;
  @override
  bool get ownsRouteCover => _actionsRoute?.isActive == true;
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;
  @override
  void clearPendingInteraction() {
    _favoriteBusy = false;
    _opening = false;
    _error = null;
    final route = _actionsRoute;
    _actionsRoute = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void didUpdateWidget(covariant EntityMoreInfo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entityId != widget.entityId) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  bool _current(HaSessionLease lease, String id) {
    if (!isHaSessionCurrent(lease) || id != entityId) return false;
    final states = ref.read(publicHaEntitiesProvider);
    return !states.isLoading && !states.hasError && states.value?[id] != null;
  }

  Future<void> _favorite() async {
    if (_favoriteBusy) return;
    final lease = captureHaSession();
    if (lease == null) return;
    final id = entityId;
    if (!_current(lease, id)) return;
    final layout = ref.read(dashboardLayoutProvider);
    if (layout.isLoading || layout.hasError || layout.value == null) return;
    final notifier = ref.read(dashboardLayoutProvider.notifier);
    setState(() => _favoriteBusy = true);
    try {
      await notifier.toggleFavorite(id, isCurrent: () => _current(lease, id));
    } catch (_) {
      if (_current(lease, id)) {
        setState(() => _error = AppLocalizations.of(context).commonError);
      }
    } finally {
      if (mounted && sessionCurrent(lease.generation)) {
        setState(() => _favoriteBusy = false);
      }
    }
  }

  Future<void> _allActions() async {
    if (_opening) return;
    final lease = captureHaSession();
    if (lease == null) return;
    final id = entityId, source = captureHaRouteSource(context);
    if (source == null || !_current(lease, id)) return;
    setState(() => _opening = true);
    final upstream = widget.sourceCurrent;
    final route = CupertinoPageRoute<void>(
      builder: (_) => HaActionsScreen(
        entityId: id,
        sourceCurrent: () => source() && (upstream?.call() ?? true),
      ),
    );
    _actionsRoute = route;
    try {
      await Navigator.of(context).push(route);
    } finally {
      if (identical(_actionsRoute, route)) _actionsRoute = null;
      if (mounted && sessionCurrent(lease.generation)) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchHaSession();
    final states = ref.watch(
      publicHaEntitiesProvider.select(
        (value) => (value.isLoading, value.hasError, value.value?[entityId]),
      ),
    );
    ref.listen(publicHaEntitiesProvider, (previous, next) {
      if (next.isLoading || next.hasError || next.value?[entityId] == null) {
        setState(() {
          sessionGeneration++;
          clearPendingInteraction();
        });
      }
    });
    final entity = haSessionAvailable && !states.$1 && !states.$2
        ? states.$3
        : null;
    final favorites =
        ref.watch(dashboardLayoutProvider).value?.favoriteEntityIds ?? const [];
    final isFavorite = favorites.contains(entityId);

    Widget content(
      BuildContext context,
      ScrollController? scrollController,
    ) => DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: entity == null
          ? Center(
              child: states.$1 && haSessionAvailable
                  ? const CupertinoActivityIndicator()
                  : Text(
                      !haSessionAvailable
                          ? AppLocalizations.of(context).mediaRemoteExpired
                          : states.$2
                          ? AppLocalizations.of(context).healthReadError
                          : AppLocalizations.of(context).moreInfoEntityNotFound,
                    ),
            )
          : ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (!asPage)
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey3.resolveFrom(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entity.friendlyName,
                        style: CupertinoTheme.of(context)
                            .textTheme
                            .navLargeTitleTextStyle,
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: _favoriteBusy ? null : haCallback(_favorite),
                      child: Icon(
                        isFavorite
                            ? CupertinoIcons.star_fill
                            : CupertinoIcons.star,
                        color: CupertinoColors.systemYellow,
                      ),
                    ),
                  ],
                ),
                Text(
                  entity.state,
                  style: TextStyle(
                    fontSize: AppText.body.fontSize,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 16),
                ActionStatusIndicator(entityId: entityId),
                if (_error != null) Text(_error!),
                _EntityQuickControls(
                  entity: entity,
                  sourceCurrent: sourceSessionCurrent,
                ),
                EntityControls(
                  entity: entity,
                  sourceCurrent: sourceSessionCurrent,
                ),
                CupertinoButton(
                  onPressed: _opening ? null : haCallback(_allActions),
                  child: Text(AppLocalizations.of(context).haAllActions),
                ),
                const SizedBox(height: 8),
                SettingsSection(
                  header: Text(
                    AppLocalizations.of(context).moreInfoDetailsHeader,
                  ),
                  children: [
                    _AttributeDetail(
                      label: AppLocalizations.of(context).moreInfoEntityId,
                      value: entity.entityId,
                    ),
                    if (entity.lastChanged != null)
                      _AttributeDetail(
                        label: AppLocalizations.of(context).moreInfoLastChanged,
                        value: entity.lastChanged!.toLocal().toString().split(
                          '.',
                        )[0],
                      ),
                    for (final attribute in entity.attributes.entries)
                      if (!_hiddenAttributeKeys.contains(attribute.key))
                        _AttributeDetail(
                          label: attribute.key,
                          value: '${attribute.value}',
                        ),
                  ],
                ),
              ],
            ),
    );
    if (asPage) return content(context, null);
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: content,
    );
  }
}

class _EntityQuickControls extends ConsumerStatefulWidget {
  const _EntityQuickControls({
    required this.entity,
    required this.sourceCurrent,
  });
  final HaEntity entity;
  final bool Function() sourceCurrent;
  @override
  ConsumerState<_EntityQuickControls> createState() =>
      _EntityQuickControlsState();
}

class _EntityQuickControlsState extends HaSessionState<_EntityQuickControls> {
  bool _busy = false;
  double? _brightness;
  String? _error;
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent();
  @override
  void clearPendingInteraction() {
    _busy = false;
    _brightness = null;
    _error = null;
  }

  @override
  void didUpdateWidget(covariant _EntityQuickControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entity.entityId != widget.entity.entityId) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  HaEntity? get _entity {
    if (!haSessionAvailable) return null;
    final states = ref.read(publicHaEntitiesProvider);
    return states.isLoading || states.hasError
        ? null
        : states.value?[widget.entity.entityId];
  }

  bool _current(HaSessionLease lease, String id) =>
      isHaSessionCurrent(lease) &&
      id == widget.entity.entityId &&
      _entity != null;
  bool _service(String domain, String service) {
    final catalog = ref.read(haActionsProvider);
    return !catalog.isLoading &&
        !catalog.hasError &&
        (catalog.value?.any(
              (action) => action.domain == domain && action.service == service,
            ) ??
            false);
  }

  Future<void> _run(
    HaSessionLease lease,
    String id,
    String service,
    Map<String, dynamic> data,
  ) async {
    if (_busy || !_current(lease, id)) return;
    final entity = _entity!;
    if (entity.state == 'unavailable' || !_service(entity.domain, service)) {
      return;
    }
    final executor = ref.read(haActionExecutorProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_current(lease, id) ||
          !identical(ref.read(haActionExecutorProvider), executor)) {
        return;
      }
      await executor.execute(
        domain: entity.domain,
        service: service,
        entityId: id,
        serviceData: data,
      );
    } catch (error) {
      if (_current(lease, id)) {
        setState(
          () => _error = actionErrorLabel(AppLocalizations.of(context), error),
        );
      }
    } finally {
      if (mounted && sessionCurrent(lease.generation)) {
        setState(() {
          _busy = false;
          _brightness = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchHaSession();
    ref.watch(
      publicHaEntitiesProvider.select(
        (states) => (
          states.isLoading,
          states.hasError,
          states.value?[widget.entity.entityId],
        ),
      ),
    );
    final entity = _entity;
    if (entity == null) return const SizedBox.shrink();
    ref.watch(haActionExecutorProvider);
    ref.watch(haActionsProvider);
    final lease = captureHaSession();
    final disabled = _busy || lease == null || entity.state == 'unavailable';
    final toggle = entity.isOn ? 'turn_off' : 'turn_on';
    final brightness = entity.attributes['brightness'];
    return Column(
      children: [
        if (entity.isToggleable && _service(entity.domain, toggle))
          SettingsSection(
            children: [
              CupertinoListTile(
                title: Text(AppLocalizations.of(context).moreInfoOn),
                trailing: CupertinoSwitch(
                  value: entity.isOn,
                  onChanged: disabled
                      ? null
                      : (_) => _run(lease, entity.entityId, toggle, {}),
                ),
              ),
            ],
          ),
        if (entity.domain == 'light' &&
            brightness is num &&
            brightness.isFinite &&
            _service('light', 'turn_on'))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Icon(CupertinoIcons.sun_max, size: 20),
                Expanded(
                  child: CupertinoSlider(
                    value: _brightness ?? (brightness / 255).clamp(0.0, 1.0),
                    onChanged: disabled
                        ? null
                        : (value) {
                            if (value.isFinite &&
                                _current(lease, entity.entityId)) {
                              setState(
                                () => _brightness = value.clamp(0.0, 1.0),
                              );
                            }
                          },
                    onChangeEnd: disabled
                        ? null
                        : (value) {
                            if (value.isFinite) {
                              _run(lease, entity.entityId, 'turn_on', {
                                'brightness_pct': (value.clamp(0.0, 1.0) * 100)
                                    .round(),
                              });
                            }
                          },
                  ),
                ),
              ],
            ),
          ),
        if (_busy) const CupertinoActivityIndicator(),
        if (_error != null) Text(_error!),
      ],
    );
  }
}

class _AttributeDetail extends StatelessWidget {
  const _AttributeDetail({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final labelWidget = Text(
          label,
          style: AppText.subhead.copyWith(
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        );
        if (constraints.maxWidth < 420 ||
            MediaQuery.textScalerOf(context).scale(16) > 24) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [labelWidget, const SizedBox(height: 4), Text(value)],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: labelWidget),
            const SizedBox(width: 16),
            Expanded(child: Text(value, textAlign: TextAlign.end)),
          ],
        );
      },
    ),
  );
}
