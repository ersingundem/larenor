import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qbittorrent_api/qbittorrent_api.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../providers/qbittorrent_providers.dart';
import 'add_torrent_sheet.dart';
import 'qbittorrent_connect_screen.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/theme/spacing.dart';

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
          CupertinoPageScaffold(child: Center(child: Text(error.toString()))),
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

    return ServiceRootScaffold(
      title: 'qBittorrent',
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
      slivers: torrentsAsync.when(
        loading: () => const [
          SliverFilledMessage(child: CupertinoActivityIndicator()),
        ],
        error: (error, _) => [
          SliverFilledMessage(
            child: Text(
              AppLocalizations.of(context).adminLoadError(error.toString()),
            ),
          ),
        ],
        data: (torrents) {
          if (torrents.isEmpty) {
            return [
              SliverFilledMessage(
                child: Text(AppLocalizations.of(context).qbittorrentNoTorrents),
              ),
            ];
          }
          return [
            SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: Gap.sm),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final torrent in torrents)
                      CupertinoListTile(
                        title: Text(
                          torrent.name ??
                              AppLocalizations.of(context).commonUnknown,
                        ),
                        subtitle: Text(
                          '${torrent.state?.name ?? AppLocalizations.of(context).commonUnknown.toLowerCase()} · '
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
              ]),
            ),
          ];
        },
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
        title: Text(
          torrent.name ??
              AppLocalizations.of(context).qbittorrentTileFallbackName,
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'pause'),
            child: Text(AppLocalizations.of(context).qbittorrentPauseAction),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'resume'),
            child: Text(AppLocalizations.of(context).qbittorrentResumeAction),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, 'delete'),
            child: Text(AppLocalizations.of(context).commonDelete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
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
