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

String _generateTileId() => DateTime.now().microsecondsSinceEpoch.toString();

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
            _ConnectionIndicator(status: connectionStatus.value),
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
        child: layoutAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) =>
              Center(child: Text('Failed to load dashboard: $error')),
          data: (layout) {
            if (layout.tiles.isEmpty) {
              return _EmptyDashboard(
                onAddTile: () => _showAddTileSheet(context),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(8),
              child: TileGrid(
                tiles: layout.tiles,
                editMode: _editMode,
                tileBuilder: (context, tile) => buildTileContent(tile),
                onTileChanged: (tile) =>
                    ref.read(dashboardLayoutProvider.notifier).updateTile(tile),
                onTileRemoved: (id) =>
                    ref.read(dashboardLayoutProvider.notifier).removeTile(id),
              ),
            );
          },
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

    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Add tile'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'entity'),
            child: const Text('Entity card'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'webview'),
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

    if (choice == 'entity' && context.mounted) {
      await _pickEntity(context, nextY);
    } else if (choice == 'webview' && context.mounted) {
      await _showUrlDialog(context, nextY);
    }
  }

  Future<void> _pickEntity(BuildContext context, int nextY) async {
    final entities = ref.read(entitiesProvider).value?.values.toList() ?? [];

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
            type: TileType.entity,
            x: 0,
            y: nextY,
            width: 2,
            height: 2,
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

class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.status});

  final HaConnectionStatus? status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      HaConnectionStatus.connected => CupertinoColors.systemGreen,
      HaConnectionStatus.connecting => CupertinoColors.systemOrange,
      _ => CupertinoColors.systemRed,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.resolveFrom(context),
        ),
      ),
    );
  }
}
