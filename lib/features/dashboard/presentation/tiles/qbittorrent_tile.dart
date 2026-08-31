import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import '../../../media/qbittorrent/providers/qbittorrent_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';

class QbittorrentTile extends ConsumerWidget {
  const QbittorrentTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(qbittorrentConnectionProvider).value != null;
    final torrents = ref.watch(qbittorrentTorrentsProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.arrow_down_circle,
      title: 'qBittorrent',
      connected: connected,
      onTap: () => Navigator.of(context).push(
        CupertinoPageRoute(builder: (_) => const QbittorrentTorrentsScreen()),
      ),
      lines: torrents.isEmpty
          ? const ['No active torrents']
          : torrents
                .take(3)
                .map(
                  (t) =>
                      '${t.name ?? 'Torrent'} · '
                      '${((t.progress ?? 0) * 100).round()}%',
                )
                .toList(),
    );
  }
}
