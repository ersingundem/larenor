import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/category_colors.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../domain/tile_config.dart';
import '../providers/dashboard_providers.dart';
import 'entity_picker_screen.dart';
import 'tile_grid.dart';
import 'tile_kinds.dart';
import 'tiles/tile_registry.dart';
import 'widget_gallery_sheet.dart';
import 'widgets/more_info_sheet.dart';

String _generateTileId() => DateTime.now().microsecondsSinceEpoch.toString();

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  bool _editMode = false;
  bool _showGallery = false;
  final _gridKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final layoutAsync = ref.watch(dashboardLayoutProvider);
    final connectionStatus = ref.watch(haConnectionStatusProvider);

    final l10n = AppLocalizations.of(context);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.appTitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_editMode)
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _showGallery = !_showGallery),
                child: Icon(
                  _showGallery
                      ? CupertinoIcons.xmark_circle_fill
                      : CupertinoIcons.add_circled,
                ),
              ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => setState(() {
                _editMode = !_editMode;
                if (!_editMode) _showGallery = false;
              }),
              child: Text(_editMode ? l10n.commonDone : l10n.commonEdit),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => context.push('/settings'),
              child: const Icon(CupertinoIcons.settings),
            ),
          ],
        ),
      ),
      child: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _ConnectionBanner(status: connectionStatus.value),
                Expanded(
                  child: layoutAsync.when(
                    loading: () =>
                        const Center(child: CupertinoActivityIndicator()),
                    error: (error, _) => Center(
                      child: Text(l10n.dashboardLoadError(error.toString())),
                    ),
                    data: (layout) {
                      final isEmpty =
                          layout.tiles.isEmpty &&
                          layout.favoriteEntityIds.isEmpty;
                      return Column(
                        children: [
                          if (layout.favoriteEntityIds.isNotEmpty)
                            _FavoritesRow(entityIds: layout.favoriteEntityIds),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: DragTarget<TileType>(
                                onAcceptWithDetails: _handleDrop,
                                builder: (context, candidateData, _) {
                                  return Stack(
                                    key: _gridKey,
                                    children: [
                                      TileGrid(
                                        tiles: layout.tiles,
                                        editMode: _editMode,
                                        tileBuilder: (context, tile) =>
                                            buildTileContent(tile),
                                        onTileChanged: (tile) => ref
                                            .read(
                                              dashboardLayoutProvider.notifier,
                                            )
                                            .updateTile(tile),
                                        onTileRemoved: (id) => ref
                                            .read(
                                              dashboardLayoutProvider.notifier,
                                            )
                                            .removeTile(id),
                                      ),
                                      if (isEmpty)
                                        Positioned.fill(
                                          child: _EmptyDashboard(
                                            onAddTile: () => setState(
                                              () => _showGallery = true,
                                            ),
                                          ),
                                        ),
                                      if (candidateData.isNotEmpty)
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: CupertinoColors
                                                      .systemBlue,
                                                  width: 3,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          if (_showGallery)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: WidgetGallery(
                  onClose: () => setState(() => _showGallery = false),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _handleDrop(DragTargetDetails<TileType> details) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(details.offset);
    final metrics = gridMetricsForWidth(box.size.width);
    final x = (local.dx / metrics.cellSize).floor().clamp(
      0,
      kGridMaxColumns - 1,
    );
    final y = (local.dy / metrics.cellSize).floor().clamp(0, 999);
    _addTileAt(details.data, x, y);
  }

  Future<void> _addTileAt(TileType type, int x, int y) async {
    setState(() => _showGallery = false);
    if (type == TileType.webview) {
      await _showUrlDialog(x, y);
    } else if (serviceTileKinds.containsKey(type)) {
      final kind = serviceTileKinds[type]!;
      await ref
          .read(dashboardLayoutProvider.notifier)
          .addTile(
            TileConfig(
              id: _generateTileId(),
              type: type,
              x: x,
              y: y,
              width: kind.width,
              height: kind.height,
            ),
          );
    } else {
      await _pickEntityForTile(type, x, y);
    }
  }

  Future<void> _pickEntityForTile(TileType type, int x, int y) async {
    final kind = tileKinds[type]!;
    final allEntities = ref.read(entitiesProvider).value?.values.toList() ?? [];
    final entities = kind.domainFilter == null
        ? allEntities
        : allEntities.where((e) => e.domain == kind.domainFilter).toList();

    final chosen = await Navigator.of(context).push<HaEntity>(
      CupertinoPageRoute(
        builder: (_) => EntityPickerScreen(entities: entities),
      ),
    );

    if (chosen == null) return;
    await ref
        .read(dashboardLayoutProvider.notifier)
        .addTile(
          TileConfig(
            id: _generateTileId(),
            type: type,
            x: x,
            y: y,
            width: kind.width,
            height: kind.height,
            entityId: chosen.entityId,
          ),
        );
  }

  Future<void> _showUrlDialog(int x, int y) async {
    final controller = TextEditingController(text: 'https://');
    final url = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(AppLocalizations.of(context).dashboardWebsiteUrlTitle),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autofocus: true,
            placeholder: 'https://example.com',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(AppLocalizations.of(context).commonAdd),
          ),
        ],
      ),
    );

    if (url == null || url.isEmpty) return;
    await ref
        .read(dashboardLayoutProvider.notifier)
        .addTile(
          TileConfig(
            id: _generateTileId(),
            type: TileType.webview,
            x: x,
            y: y,
            width: 4,
            height: 4,
            url: url,
          ),
        );
  }
}

class _FavoritesRow extends ConsumerWidget {
  const _FavoritesRow({required this.entityIds});

  final List<String> entityIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entities = ref.watch(entitiesProvider).value ?? const {};

    return SizedBox(
      height: 76,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          for (final entityId in entityIds)
            if (entities[entityId] case final entity?)
              Builder(
                builder: (context) {
                  final categoryColor = categoryColorForDomain(
                    entity.domain,
                    deviceClass: entity.attributes['device_class'] as String?,
                  );
                  return GestureDetector(
                    onTap: () => showEntityMoreInfo(context, entityId),
                    child: Container(
                      width: 88,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: entity.isOn
                            ? CupertinoDynamicColor.resolve(
                                categoryColor,
                                context,
                              ).withValues(alpha: 0.15)
                            : CupertinoColors.secondarySystemGroupedBackground
                                  .resolveFrom(context),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.star_fill,
                            size: 18,
                            color: categoryColor,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entity.friendlyName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
        ],
      ),
    );
  }
}

class _EmptyDashboard extends StatelessWidget {
  const _EmptyDashboard({required this.onAddTile});

  final VoidCallback onAddTile;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.square_grid_2x2,
            size: 48,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(height: 12),
          Text(AppLocalizations.of(context).dashboardEmptyTitle),
          const SizedBox(height: 12),
          CupertinoButton.filled(
            onPressed: onAddTile,
            child: Text(AppLocalizations.of(context).dashboardAddTileButton),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBanner extends StatefulWidget {
  const _ConnectionBanner({required this.status});

  final HaConnectionStatus? status;

  @override
  State<_ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends State<_ConnectionBanner> {
  bool _dismissed = false;

  @override
  void didUpdateWidget(covariant _ConnectionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _dismissed = false;
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    if (_dismissed ||
        status == null ||
        status == HaConnectionStatus.connected) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final message = status == HaConnectionStatus.connecting
        ? l10n.dashboardConnectingMessage
        : l10n.dashboardUnreachableMessage;

    return Container(
      width: double.infinity,
      color: CupertinoColors.systemOrange,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.wifi_slash,
            size: 16,
            color: CupertinoColors.white,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 13,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _dismissed = true),
            child: const Icon(
              CupertinoIcons.xmark,
              size: 16,
              color: CupertinoColors.white,
            ),
          ),
        ],
      ),
    );
  }
}
