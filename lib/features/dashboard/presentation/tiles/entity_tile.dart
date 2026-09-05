import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import 'home_accessory_tile.dart';

/// Saved entity widgets share the same guarded controls as room accessories.
class EntityTile extends ConsumerWidget {
  const EntityTile({super.key, required this.tile});
  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (loading, failed, entity) = ref.watch(
      entitiesProvider.select(
        (states) => (
          states.isLoading,
          states.hasError,
          states.isLoading || states.hasError
              ? null
              : states.value?[tile.entityId],
        ),
      ),
    );
    if (entity == null) {
      final l10n = AppLocalizations.of(context);
      return ColoredBox(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: loading
                ? const CupertinoActivityIndicator()
                : Text(
                    failed ? l10n.healthReadError : l10n.commonUnknownEntity,
                    textAlign: TextAlign.center,
                  ),
          ),
        ),
      );
    }
    return HomeAccessoryTile(
      key: ValueKey(entity.entityId),
      entity: entity,
      title: tile.title,
      enableContextMenu: false,
    );
  }
}
