import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import '../widgets/more_info_sheet.dart';
import 'entity_icons.dart';

class EntityTile extends ConsumerWidget {
  const EntityTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entitiesAsync = ref.watch(entitiesProvider);
    final entity = entitiesAsync.value?[tile.entityId];

    if (entity == null) {
      return ColoredBox(
        color: CupertinoColors.systemGrey5,
        child: Center(
          child: Text(AppLocalizations.of(context).commonUnknownEntity),
        ),
      );
    }

    final categoryColor = categoryColorForDomain(
      entity.domain,
      deviceClass: entity.attributes['device_class'] as String?,
    );
    final background = entity.isOn
        ? CupertinoDynamicColor.resolve(
            categoryColor,
            context,
          ).withValues(alpha: 0.15)
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);

    return GestureDetector(
      onTap: () => showEntityMoreInfo(context, entity.entityId),
      child: ColoredBox(
        color: background,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 32, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(iconForEntity(entity), size: 26, color: categoryColor),
              Text(
                entity.friendlyName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
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
      ),
    );
  }
}
