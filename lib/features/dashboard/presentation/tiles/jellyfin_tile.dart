import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../media/jellyfin/presentation/jellyfin_home_screen.dart';
import '../../../media/jellyfin/providers/jellyfin_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';

class JellyfinTile extends ConsumerWidget {
  const JellyfinTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(jellyfinConnectionProvider).value != null;
    final items = ref.watch(jellyfinResumeItemsProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.play_rectangle,
      title: 'Jellyfin',
      connected: connected,
      onTap: () => Navigator.of(context)
          .push(CupertinoPageRoute(builder: (_) => const JellyfinHomeScreen())),
      lines: items.isEmpty
          ? const ['Nothing in progress']
          : items.take(3).map((item) => item.name).toList(),
    );
  }
}
