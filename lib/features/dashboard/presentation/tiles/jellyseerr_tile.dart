import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import '../../../media/jellyseerr/presentation/jellyseerr_status_label.dart';
import '../../../media/jellyseerr/providers/jellyseerr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class JellyseerrTile extends ConsumerWidget {
  const JellyseerrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(jellyseerrConnectionProvider).value != null;
    final items = ref.watch(jellyseerrMyRequestsProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.search,
      service: AppService.jellyseerr,
      title: 'Jellyseerr',
      connected: connected,
      onTap: () => Navigator.of(
        context,
      ).push(CupertinoPageRoute(builder: (_) => const JellyseerrHomeScreen())),
      lines: items.isEmpty
          ? [AppLocalizations.of(context).jellyseerrTileNoRequests]
          : items
                .take(3)
                .map(
                  (item) =>
                      '${item.displayTitle} · ${jellyseerrRequestStatusLabel(context, item.status)}',
                )
                .toList(),
    );
  }
}
