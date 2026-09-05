import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../media/qbittorrent/presentation/qbittorrent_torrents_screen.dart';
import '../../../media/qbittorrent/providers/qbittorrent_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class QbittorrentTile extends ConsumerWidget {
  const QbittorrentTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(qbittorrentConnectionProvider);
    final connected =
        !connection.isLoading &&
        !connection.hasError &&
        connection.value != null;
    final torrents = ref.watch(qbittorrentTorrentsProvider);
    final l10n = AppLocalizations.of(context);
    final lines = connection.hasError
        ? [l10n.healthReadError]
        : connection.isLoading || torrents.isLoading
        ? [l10n.commonLoading]
        : torrents.hasError
        ? [l10n.healthReadError]
        : (torrents.value?.isEmpty ?? true)
        ? [l10n.qbittorrentTileNoActive]
        : torrents.value!
              .take(3)
              .map(
                (torrent) =>
                    '${torrent.name ?? l10n.qbittorrentTileFallbackName} · ${torrentProgressLabel(l10n, torrent.progress)}',
              )
              .toList();
    return ServiceTileShell(
      icon: CupertinoIcons.arrow_down_circle,
      service: AppService.qbittorrent,
      title: 'qBittorrent',
      connected: connected || connection.isLoading || connection.hasError,
      onTap: () {
        if (context.mounted) context.push('/system/qbittorrent');
      },
      lines: lines,
    );
  }
}
