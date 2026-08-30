import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';

class EntityTile extends ConsumerWidget {
  const EntityTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entitiesAsync = ref.watch(entitiesProvider);
    final entity = entitiesAsync.value?[tile.entityId];

    if (entity == null) {
      return const ColoredBox(
        color: CupertinoColors.systemGrey5,
        child: Center(child: Text('Unknown entity')),
      );
    }

    final background = entity.isOn
        ? CupertinoColors.activeBlue.withValues(alpha: 0.15)
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);

    return ColoredBox(
      color: background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 32, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(
              _iconFor(entity.domain),
              size: 26,
              color: CupertinoTheme.of(context).primaryColor,
            ),
            Text(
              entity.friendlyName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    entity.state,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ),
                if (entity.isToggleable)
                  CupertinoSwitch(
                    value: entity.isOn,
                    onChanged: (_) =>
                        ref.read(entitiesProvider.notifier).toggle(entity),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String domain) {
    switch (domain) {
      case 'light':
        return CupertinoIcons.lightbulb;
      case 'switch':
        return CupertinoIcons.power;
      case 'sensor':
        return CupertinoIcons.graph_circle;
      case 'climate':
        return CupertinoIcons.thermometer;
      case 'fan':
        return CupertinoIcons.wind;
      case 'input_boolean':
        return CupertinoIcons.checkmark_square;
      case 'media_player':
        return CupertinoIcons.play_circle;
      case 'cover':
        return CupertinoIcons.rectangle_split_3x1;
      default:
        return CupertinoIcons.square_grid_2x2;
    }
  }
}
