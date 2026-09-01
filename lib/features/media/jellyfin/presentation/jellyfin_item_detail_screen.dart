import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../data/models/jellyfin_item.dart';
import '../providers/jellyfin_providers.dart';
import 'jellyfin_library_screen.dart';
import 'player/jellyfin_player_screen.dart';

class JellyfinItemDetailScreen extends ConsumerWidget {
  const JellyfinItemDetailScreen({super.key, required this.item});

  final JellyfinItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(jellyfinClientProvider);
    final imageUrl = client?.imageUrl(item.id);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(item.name)),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (imageUrl != null)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              item.name,
              style: CupertinoTheme.of(context)
                  .textTheme
                  .navLargeTitleTextStyle,
            ),
            if (item.productionYear != null || item.seriesName != null)
              Text(
                [
                  item.seriesName,
                  item.productionYear?.toString(),
                ].whereType<String>().join(' · '),
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            if (item.overview != null) ...[
              const SizedBox(height: 12),
              Text(item.overview!),
            ],
            const SizedBox(height: 20),
            if (item.isPlayable)
              CupertinoButton.filled(
                onPressed: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => JellyfinPlayerScreen(item: item),
                  ),
                ),
                child: Text(AppLocalizations.of(context).jellyfinPlayButton),
              )
            else
              CupertinoButton.filled(
                onPressed: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => JellyfinLibraryScreen(
                      parentId: item.id,
                      title: item.name,
                    ),
                  ),
                ),
                child: Text(AppLocalizations.of(context).jellyfinBrowseButton),
              ),
          ],
        ),
      ),
    );
  }
}
