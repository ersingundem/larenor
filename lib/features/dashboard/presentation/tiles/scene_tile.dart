import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../../shared/theme/icon_sizes.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import 'tile_action_support.dart';

class SceneTile extends ConsumerStatefulWidget {
  const SceneTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<SceneTile> createState() => _SceneTileState();
}

class _SceneTileState extends ConsumerState<SceneTile>
    with TileActionSupport<SceneTile> {
  @override
  String? get actionEntityId => widget.tile.entityId;

  @override
  void didUpdateWidget(covariant SceneTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tile.entityId != actionEntityId) resetTileAction();
  }

  @override
  Widget build(BuildContext context) {
    watchTileActions();
    final entity = ref.watch(entitiesProvider).value?[actionEntityId];
    final name =
        entity?.friendlyName ??
        actionEntityId ??
        AppLocalizations.of(context).dashboardTileScene;
    final enabled =
        !tileActionBusy &&
        entity?.domain == 'scene' &&
        tileServiceAvailable(entity!, 'turn_on');

    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        key: ValueKey('scene-action-$actionEntityId'),
        onTap: enabled ? () => executeTileAction('scene', 'turn_on') : null,
        child: ColoredBox(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          child: Padding(
            padding: Insets.tile,
            child: TileContentViewport(
              builder: (context, availableHeight) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    CupertinoIcons.wand_stars,
                    size: IconSizes.tile,
                    color: categoryColorForDomain(context, 'scene'),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tileTitle,
                      ),
                      TileActionFeedback(
                        entityId: actionEntityId,
                        error: tileActionError,
                        busy: tileActionBusy,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
