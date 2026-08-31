import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../domain/tile_config.dart';
import '../providers/dashboard_providers.dart';
import 'entity_picker_screen.dart';
import 'tile_grid.dart';
import 'tiles/tile_registry.dart';
import 'widgets/more_info_sheet.dart';

String _generateTileId() => DateTime.now().microsecondsSinceEpoch.toString();

class _TileKind {
  const _TileKind(
    this.label, {
    this.domainFilter,
    this.width = 2,
    this.height = 2,
  });

  final String label;
  final String? domainFilter;
  final int width;
  final int height;
}

const _tileKinds = {
  TileType.entity: _TileKind('Entity card'),
  TileType.scene: _TileKind('Scene button', domainFilter: 'scene'),
  TileType.mediaPlayer: _TileKind(
    'Media player',
    domainFilter: 'media_player',
    width: 3,
    height: 3,
  ),
  TileType.climate: _TileKind(
    'Climate',
    domainFilter: 'climate',
    width: 3,
    height: 3,
  ),
  TileType.weather: _TileKind(
    'Weather',
    domainFilter: 'weather',
    width: 4,
    height: 3,
  ),
  TileType.history: _TileKind('History graph', width: 4, height: 3),
  TileType.camera: _TileKind(
    'Camera',
    domainFilter: 'camera',
    width: 3,
    height: 3,
  ),
};

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  bool _editMode = false;

  @override
  Widget build(BuildContext context) {
    final layoutAsync = ref.watch(dashboardLayoutProvider);
    final connectionStatus = ref.watch(haConnectionStatusProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Oikos'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_editMode)
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => _showAddTileSheet(context),
                child: const Icon(CupertinoIcons.add),
              ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => setState(() => _editMode = !_editMode),
              child: Text(_editMode ? 'Done' : 'Edit'),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => context.push('/settings'),
              child: const Icon(CupertinoIcons.settings),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _ConnectionBanner(status: connectionStatus.value),
            Expanded(
              child: layoutAsync.when(
                loading: () =>
                    const Center(child: CupertinoActivityIndicator()),
                error: (error, _) =>
                    Center(child: Text('Failed to load dashboard: $error')),
                data: (layout) {
                  if (layout.tiles.isEmpty &&
                      layout.favoriteEntityIds.isEmpty) {
                    return _EmptyDashboard(
                      onAddTile: () => _showAddTileSheet(context),
                    );
                  }
                  return Column(
                    children: [
                      if (layout.favoriteEntityIds.isNotEmpty)
                        _FavoritesRow(entityIds: layout.favoriteEntityIds),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: TileGrid(
                            tiles: layout.tiles,
                            editMode: _editMode,
                            tileBuilder: (context, tile) =>
                                buildTileContent(tile),
                            onTileChanged: (tile) => ref
                                .read(dashboardLayoutProvider.notifier)
                                .updateTile(tile),
                            onTileRemoved: (id) => ref
                                .read(dashboardLayoutProvider.notifier)
                                .removeTile(id),
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
    );
  }

  Future<void> _showAddTileSheet(BuildContext context) async {
    final layout = ref.read(dashboardLayoutProvider).value;
    final nextY = layout == null || layout.tiles.isEmpty
        ? 0
        : layout.tiles
              .map((t) => t.y + t.height)
              .reduce((a, b) => a > b ? a : b);

    final choice = await showCupertinoModalPopup<TileType>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Add tile'),
        actions: [
          for (final entry in _tileKinds.entries)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Text(entry.value.label),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, TileType.webview),
            child: const Text('Fullscreen website'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          isDestructiveAction: true,
          child: const Text('Cancel'),
        ),
      ),
    );

    if (choice == null || !context.mounted) return;
    if (choice == TileType.webview) {
      await _showUrlDialog(context, nextY);
    } else {
      await _pickEntityForTile(context, choice, nextY);
    }
  }

  Future<void> _pickEntityForTile(
    BuildContext context,
    TileType type,
    int nextY,
  ) async {
    final kind = _tileKinds[type]!;
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
            x: 0,
            y: nextY,
            width: kind.width,
            height: kind.height,
            entityId: chosen.entityId,
          ),
        );
  }

  Future<void> _showUrlDialog(BuildContext context, int nextY) async {
    final controller = TextEditingController(text: 'https://');
    final url = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Website URL'),
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
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
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
            x: 0,
            y: nextY,
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
              GestureDetector(
                onTap: () => showEntityMoreInfo(context, entityId),
                child: Container(
                  width: 88,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: entity.isOn
                        ? CupertinoColors.activeBlue.withValues(alpha: 0.15)
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
                        color: CupertinoTheme.of(context).primaryColor,
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
          const Text('Your dashboard is empty'),
          const SizedBox(height: 12),
          CupertinoButton.filled(
            onPressed: onAddTile,
            child: const Text('Add a tile'),
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

    final message = status == HaConnectionStatus.connecting
        ? 'Connecting to Home Assistant…'
        : 'Home Assistant unreachable, retrying…';

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
