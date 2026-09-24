import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../home_resources/data/home_resources_providers.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../navigation/search/domain/navigation_target.dart';
import '../../domain/tile_config.dart';
import 'dashboard_tile_button.dart';

class CoreResourceTile extends ConsumerWidget {
  const CoreResourceTile({super.key, required this.tile});
  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final binding = tile.coreResource;
    final catalog = ref.watch(sharedHomeResourcesProvider);
    HomeResourceRecord? current;
    if (binding != null && catalog?.fresh == true && !catalog!.stale) {
      current = catalog.entries
          .where((entry) => binding.matches(entry, catalog.userRevision))
          .firstOrNull;
    }
    final active = current != null;
    final title = current?.label ?? tile.title ?? l10n.coreResourceCardTitle;
    final state = active
        ? l10n.coreResourceBindingCurrent
        : l10n.coreResourceBindingStale;
    final captured = current;
    return DashboardTileButton(
      key: ValueKey('core-resource-card-${binding?.resourceId ?? tile.id}'),
      label: '$title. $state',
      onPressed: captured == null
          ? null
          : () {
              if (!context.mounted) return;
              final latest = ref.read(sharedHomeResourcesProvider);
              final revision = latest?.userRevision;
              if (latest == null ||
                  !latest.fresh ||
                  latest.stale ||
                  revision == null) {
                return;
              }
              final exact = latest.entries
                  .where((entry) => binding!.matches(entry, revision))
                  .firstOrNull;
              if (exact == null) return;
              context.push(
                CoreResourceNavigationTarget.fromRecord(
                  exact,
                  userRevision: revision,
                ).location,
              );
            },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                binding?.kind == HomeResourceKind.room
                    ? CupertinoIcons.house
                    : CupertinoIcons.square_stack_3d_up,
                color: active
                    ? CupertinoColors.activeBlue.resolveFrom(context)
                    : CupertinoColors.systemOrange.resolveFrom(context),
              ),
              const Spacer(),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.tileTitle.copyWith(
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
              Text(
                state,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tileSubtitle.copyWith(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
