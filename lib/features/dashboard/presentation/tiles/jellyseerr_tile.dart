import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../media/jellyseerr/presentation/jellyseerr_home_screen.dart';
import '../../../media/jellyseerr/providers/jellyseerr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';

class JellyseerrTile extends ConsumerWidget {
  const JellyseerrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(jellyseerrConnectionProvider).value != null;
    final items = ref.watch(jellyseerrMyRequestsProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.search,
      title: 'Jellyseerr',
      connected: connected,
      onTap: () => Navigator.of(
        context,
      ).push(CupertinoPageRoute(builder: (_) => const JellyseerrHomeScreen())),
      lines: items.isEmpty
          ? const ['No requests']
          : items
                .take(3)
                .map((item) => '${item.displayTitle} · ${item.status.label}')
                .toList(),
    );
  }
}
