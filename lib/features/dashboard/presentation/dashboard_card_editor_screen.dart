import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../settings/data/app_service.dart';
import '../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../../wellbeing/providers/wellbeing_providers.dart';
import '../domain/dashboard_card_size.dart';
import '../domain/dashboard_layout.dart';
import '../domain/tile_config.dart';
import '../../web_panel/presentation/web_panel_settings_screen.dart';
import '../providers/dashboard_providers.dart';
import 'dashboard_card_presentation.dart';
import 'dashboard_edit_guard.dart';
import 'tile_kinds.dart';

enum DashboardEditorMode { room, widgets, services }

/// Static layout previews only: no tile registry, client, polling or commands.
class DashboardCardEditorScreen extends ConsumerStatefulWidget {
  const DashboardCardEditorScreen({
    super.key,
    required this.mode,
    this.roomId,
    this.services = const [],
  });
  final DashboardEditorMode mode;
  final String? roomId;
  final List<AppService> services;
  @override
  ConsumerState<DashboardCardEditorScreen> createState() =>
      _DashboardCardEditorScreenState();
}

class _DashboardCardEditorScreenState
    extends DashboardEditState<DashboardCardEditorScreen> {
  bool _busy = false;
  String? _message;
  Route<DashboardCardSize?>? _sizeRoute;
  Route<TileConfig>? _webRoute;

  @override
  void invalidateDashboardInteraction() {
    _message = null;
    final route = _sizeRoute;
    _sizeRoute = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
    final webRoute = _webRoute;
    _webRoute = null;
    if (webRoute?.isActive == true) webRoute!.navigator?.removeRoute(webRoute);
  }

  Future<void> _change(Future<void> Function() change, int generation) async {
    if (_busy || !interactionCurrent(generation)) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await change();
    } catch (_) {
      if (interactionCurrent(generation)) {
        setState(
          () => _message = AppLocalizations.of(context).dashboardEditFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<String> _ids(DashboardLayout layout) => switch (widget.mode) {
    DashboardEditorMode.room =>
      layout.rooms
              .where((room) => room.id == widget.roomId)
              .firstOrNull
              ?.entityIds ??
          [],
    DashboardEditorMode.widgets => layout.tiles.map((tile) => tile.id).toList(),
    DashboardEditorMode.services =>
      widget.services.map((service) => service.name).toList(),
  };

  void _move(List<String> ids, int oldIndex, int newIndex, int generation) {
    if (_busy ||
        _sizeRoute != null ||
        oldIndex == newIndex ||
        !interactionCurrent(generation)) {
      return;
    }
    final reordered = [...ids];
    final id = reordered.removeAt(oldIndex);
    reordered.insert(newIndex.clamp(0, reordered.length), id);
    _change(
      () => switch (widget.mode) {
        DashboardEditorMode.room =>
          ref
              .read(dashboardLayoutProvider.notifier)
              .reorderEntitiesInRoom(widget.roomId!, reordered),
        DashboardEditorMode.widgets =>
          ref.read(dashboardLayoutProvider.notifier).reorderTiles(reordered),
        DashboardEditorMode.services => Future<void>.value(),
      },
      generation,
    );
  }

  Future<void> _size(String id, int generation) async {
    if (_busy || _sizeRoute != null || !interactionCurrent(generation)) return;
    var selected = false;
    final route = CupertinoModalPopupRoute<DashboardCardSize?>(
      builder: (context) => CupertinoActionSheet(
        title: Text(AppLocalizations.of(context).dashboardCardSize),
        actions: [
          for (final size in <DashboardCardSize?>[
            ...DashboardCardSize.values,
            null,
          ])
            CupertinoActionSheetAction(
              key: ValueKey('dashboard-size-${size?.name ?? 'default'}'),
              onPressed: () {
                if (!context.mounted ||
                    ModalRoute.of(context)?.isCurrent != true) {
                  return;
                }
                selected = true;
                closeDashboardModal(context, size);
              },
              child: Text(cardSizeLabel(AppLocalizations.of(context), size)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => closeDashboardModal(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    _sizeRoute = route;
    final size = await Navigator.of(context).push<DashboardCardSize?>(route);
    if (identical(_sizeRoute, route)) _sizeRoute = null;
    if (!selected || !interactionCurrent(generation)) return;
    await _change(() {
      final notifier = ref.read(dashboardLayoutProvider.notifier);
      switch (widget.mode) {
        case DashboardEditorMode.room:
          return notifier.setEntityCardSize(id, size);
        case DashboardEditorMode.services:
          return notifier.setServiceCardSize(
            AppService.values.byName(id),
            size,
          );
        case DashboardEditorMode.widgets:
          final current = ref.read(dashboardLayoutProvider);
          final tile = current.value?.tiles
              .where((tile) => tile.id == id)
              .firstOrNull;
          if (current.isLoading || current.hasError || tile == null) {
            throw StateError('Layout changed');
          }
          final span = cardSizeSpan(size ?? DashboardCardSize.large);
          return notifier.updateTile(
            tile.copyWith(width: span.columns, height: span.rows),
          );
      }
    }, generation);
  }

  Future<void> _webSettings(TileConfig tile, int generation) async {
    if (_busy ||
        _webRoute != null ||
        _sizeRoute != null ||
        !interactionCurrent(generation)) {
      return;
    }
    final route = CupertinoPageRoute<TileConfig>(
      builder: (_) => WebPanelSettingsScreen(initialTile: tile),
    );
    _webRoute = route;
    final updated = await pushDashboardPage(route);
    if (identical(_webRoute, route)) _webRoute = null;
    if (updated == null || !interactionCurrent(generation)) return;
    await _change(
      () => ref
          .read(dashboardLayoutProvider.notifier)
          .updateTile(
            updated,
            expectedTile: tile,
            isCurrent: () => interactionCurrent(generation),
          ),
      generation,
    );
  }

  @override
  Widget build(BuildContext context) {
    watchDashboardAccount();
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(dashboardLayoutProvider);
    final privacy = ref.watch(wellbeingPrivateEntityIdsProvider);
    final generation = interactionGeneration;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.dashboardEditLayout),
      ),
      child: !foreground
          ? const SizedBox.expand()
          : SafeArea(
              child: state.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () =>
                    const Center(child: CupertinoActivityIndicator()),
                error: (_, _) => Center(child: Text(l10n.dashboardEditFailed)),
                data: (layout) {
                  final ids = _ids(layout);
                  final tilesById = {
                    for (final tile in layout.tiles) tile.id: tile,
                  };
                  final room = layout.rooms
                      .where((room) => room.id == widget.roomId)
                      .firstOrNull;
                  // Read cached names only. Opening this editor must not establish HA
                  // subscriptions or activate any external-service providers.
                  final cached = ref.exists(entitiesProvider)
                      ? ref.read(entitiesProvider)
                      : null;
                  final names =
                      cached != null &&
                          !cached.isLoading &&
                          !cached.hasError &&
                          (room == null || roomMatchesCurrentServer(ref, room))
                      ? cached.value
                      : null;
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          l10n.dashboardEditHint,
                          style: AppText.footnote,
                        ),
                      ),
                      if (_message != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(_message!),
                        ),
                      if (ids.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(l10n.homeNoCategoryDevices),
                        ),
                      Expanded(
                        child: ReorderableList(
                          itemCount: ids.length,
                          onReorderItem: (oldIndex, newIndex) {
                            if (widget.mode == DashboardEditorMode.services) {
                              return;
                            }
                            _move(ids, oldIndex, newIndex, generation);
                          },
                          itemBuilder: (context, index) {
                            final id = ids[index];
                            final tile = tilesById[id];
                            final entityId =
                                widget.mode == DashboardEditorMode.room
                                ? id
                                : tile?.entityId;
                            if (entityId != null &&
                                !isPublicHaEntity(privacy, entityId)) {
                              return SizedBox.shrink(
                                key: ValueKey('dashboard-edit-$id'),
                              );
                            }
                            final name = switch (widget.mode) {
                              DashboardEditorMode.room =>
                                names?[id]?.friendlyName ?? id,
                              DashboardEditorMode.services => tileTypeLabel(
                                context,
                                serviceTileTypes[AppService.values.byName(id)]!,
                              ),
                              DashboardEditorMode.widgets =>
                                tile?.title ??
                                    (tile == null
                                        ? id
                                        : tileTypeLabel(context, tile.type)),
                            };
                            final size = switch (widget.mode) {
                              DashboardEditorMode.room =>
                                layout.entityCardSizes[id],
                              DashboardEditorMode.services =>
                                layout.serviceCardSizes[id],
                              DashboardEditorMode.widgets => null,
                            };
                            final sizeText =
                                widget.mode == DashboardEditorMode.widgets &&
                                    tile != null
                                ? '${tile.width} × ${tile.height}'
                                : cardSizeLabel(l10n, size);
                            final reorderable =
                                widget.mode != DashboardEditorMode.services;
                            return Padding(
                              key: ValueKey('dashboard-edit-$id'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: CupertinoColors
                                      .secondarySystemGroupedBackground
                                      .resolveFrom(context),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            CupertinoIcons.square_grid_2x2,
                                            size: 24,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              name,
                                              style: AppText.headline,
                                            ),
                                          ),
                                          if (reorderable && !_busy)
                                            ReorderableDragStartListener(
                                              index: index,
                                              child: const Padding(
                                                padding: EdgeInsets.all(12),
                                                child: Icon(
                                                  CupertinoIcons
                                                      .line_horizontal_3,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      if (widget.mode ==
                                              DashboardEditorMode.room &&
                                          layout.hiddenEntityIds.contains(id))
                                        Text(l10n.dashboardCardHidden),
                                      Wrap(
                                        spacing: 8,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          if (tile?.type == TileType.webview)
                                            CupertinoButton(
                                              key: ValueKey(
                                                'dashboard-web-settings-$id',
                                              ),
                                              onPressed: _busy
                                                  ? null
                                                  : () => _webSettings(
                                                      tile!,
                                                      generation,
                                                    ),
                                              child: Text(
                                                l10n.webPanelSettings,
                                              ),
                                            ),
                                          CupertinoButton(
                                            key: ValueKey(
                                              'dashboard-edit-size-$id',
                                            ),
                                            onPressed: _busy
                                                ? null
                                                : () => _size(id, generation),
                                            child: Text(
                                              '${l10n.dashboardCardSize}: $sizeText',
                                            ),
                                          ),
                                          if (reorderable) ...[
                                            CupertinoButton(
                                              key: ValueKey(
                                                'dashboard-edit-up-$id',
                                              ),
                                              onPressed: _busy || index == 0
                                                  ? null
                                                  : () => _move(
                                                      ids,
                                                      index,
                                                      index - 1,
                                                      generation,
                                                    ),
                                              child: Semantics(
                                                label: l10n.dashboardMoveUp,
                                                child: const Icon(
                                                  CupertinoIcons.arrow_up,
                                                ),
                                              ),
                                            ),
                                            CupertinoButton(
                                              key: ValueKey(
                                                'dashboard-edit-down-$id',
                                              ),
                                              onPressed:
                                                  _busy ||
                                                      index == ids.length - 1
                                                  ? null
                                                  : () => _move(
                                                      ids,
                                                      index,
                                                      index + 1,
                                                      generation,
                                                    ),
                                              child: Semantics(
                                                label: l10n.dashboardMoveDown,
                                                child: const Icon(
                                                  CupertinoIcons.arrow_down,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
    );
  }
}
