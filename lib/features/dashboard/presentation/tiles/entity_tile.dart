import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import '../widgets/more_info_sheet.dart';
import 'entity_icons.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/icon_sizes.dart';
import '../../../../shared/theme/spacing.dart';

class EntityTile extends ConsumerWidget {
  const EntityTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entitiesAsync = ref.watch(entitiesProvider);
    final entity = entitiesAsync.value?[tile.entityId];

    if (entity == null) {
      return ColoredBox(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        child: Center(
          child: Text(AppLocalizations.of(context).commonUnknownEntity),
        ),
      );
    }

    final categoryColor = categoryColorForDomain(
      context,
      entity.domain,
      deviceClass: entity.attributes['device_class'] as String?,
    );
    final background = entity.isOn
        ? categoryColor.withValues(alpha: 0.15)
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);

    return GestureDetector(
      onTap: () => showEntityMoreInfo(context, entity.entityId),
      child: ColoredBox(
        color: background,
        child: Padding(
          padding: Insets.tile,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(
                iconForEntity(entity),
                size: IconSizes.tile,
                color: categoryColor,
              ),
              Text(
                entity.friendlyName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.tileTitle,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      entity.state,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.tileSubtitle.copyWith(
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
