import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../media/arr/presentation/lidarr_screen.dart';
import '../../../media/arr/providers/lidarr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';

class LidarrTile extends ConsumerWidget {
  const LidarrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(lidarrConnectionProvider).value != null;
    final items = ref.watch(lidarrCalendarProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.music_note,
      title: 'Lidarr',
      connected: connected,
      onTap: () =>
          Navigator.of(context)
              .push(CupertinoPageRoute(builder: (_) => const LidarrScreen())),
      lines: items.isEmpty
          ? const ['Nothing upcoming']
          : items.take(3).map((item) => item.title).toList(),
    );
  }
}
