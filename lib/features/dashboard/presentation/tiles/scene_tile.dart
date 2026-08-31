import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/category_colors.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';

class SceneTile extends ConsumerWidget {
  const SceneTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(entitiesProvider).value?[tile.entityId];
    final name = entity?.friendlyName ?? tile.entityId ?? 'Scene';

    return GestureDetector(
      onTap: () => ref
          .read(haRestClientProvider)
          ?.callService('scene', 'turn_on', entityId: tile.entityId),
      child: ColoredBox(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(
                CupertinoIcons.wand_stars,
                size: 26,
                color: categoryColorForDomain('scene'),
              ),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
