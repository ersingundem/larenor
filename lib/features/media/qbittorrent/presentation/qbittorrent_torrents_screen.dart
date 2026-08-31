import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qbittorrent_api/qbittorrent_api.dart';

import '../providers/qbittorrent_providers.dart';
import 'add_torrent_sheet.dart';
import 'qbittorrent_connect_screen.dart';

class QbittorrentTorrentsScreen extends ConsumerWidget {
  const QbittorrentTorrentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(qbittorrentConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
      data: (config) {
        if (config == null) return const QbittorrentConnectScreen();
        return const _TorrentsList();
      },
    );
  }
}

class _TorrentsList extends ConsumerWidget {
  const _TorrentsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final torrentsAsync = ref.watch(qbittorrentTorrentsProvider);
    final clientAsync = ref.watch(qbittorrentClientProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('qBittorrent'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(qbittorrentTorrentsProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: clientAsync.value == null
              ? null
              : () async {
                  await showAddTorrentSheet(
                    context,
                    clientAsync.value!,
                    () => ref.invalidate(qbittorrentTorrentsProvider),
                  );
                },
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: torrentsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (torrents) {
            if (torrents.isEmpty) {
              return const Center(child: Text('No torrents'));
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final torrent in torrents)
                      CupertinoListTile(
                        title: Text(torrent.name ?? 'Unknown'),
                        subtitle: Text(
                          '${torrent.state?.name ?? 'unknown'} · '
                          '${((torrent.progress ?? 0) * 100).round()}%',
                        ),
                        trailing: const CupertinoListTileChevron(),
                        onTap: clientAsync.value == null
                            ? null
                            : () => _showActions(
                                context,
                                ref,
                                clientAsync.value!,
                                torrent,
                              ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showActions(
    BuildContext context,
    WidgetRef ref,
    QBittorrentApiV2 client,
    TorrentInfo torrent,
  ) async {
    final hash = torrent.hash;
    if (hash == null) return;

    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(torrent.name ?? 'Torrent'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'pause'),
            child: const Text('Pause'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'resume'),
            child: const Text('Resume'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, 'delete'),
            child: const Text('Delete'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );

    final selected = Torrents(hashes: [hash]);
    switch (action) {
      case 'pause':
        await client.torrents.pauseTorrents(torrents: selected);
      case 'resume':
        await client.torrents.resumeTorrents(torrents: selected);
      case 'delete':
        await client.torrents.deleteTorrents(
          torrents: selected,
          deleteFiles: false,
        );
    }
    if (action != null) ref.invalidate(qbittorrentTorrentsProvider);
  }
}
