import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../data/models/jellyfin_item.dart';
import '../providers/jellyfin_providers.dart';
import 'jellyfin_library_screen.dart';
import 'jellyfin_series_screen.dart';
import 'player/jellyfin_player_screen.dart';
import '../../casting/presentation/remote_playback_button.dart';

class JellyfinItemDetailScreen extends ConsumerWidget {
  const JellyfinItemDetailScreen({super.key, required this.item});

  final JellyfinItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(jellyfinClientProvider);
    final imageUrl = client?.imageUrl(item.id);
    final l10n = AppLocalizations.of(context);
    final metadata = [
      item.seriesName,
      item.productionYear?.toString(),
    ].whereType<String>().join(' · ');

    return ServiceRootScaffold(
      title: item.name,
      slivers: [
        if (imageUrl != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
            sliver: SliverToBoxAdapter(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Gap.md),
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('jellyfin-item-detail-title'),
              container: true,
              header: true,
              child: Text(item.name),
            ),
            children: [
              CupertinoListTile(
                leading: Icon(
                  item.isPlayable ? CupertinoIcons.film : CupertinoIcons.folder,
                ),
                title: Text(item.name),
                subtitle: Text(metadata.isEmpty ? item.type : metadata),
              ),
              if (item.overview != null)
                CupertinoListTile(title: Text(item.overview!)),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: SettingsSection(
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('jellyfin-item-primary-action'),
                leading: Icon(
                  item.isPlayable
                      ? CupertinoIcons.play_fill
                      : CupertinoIcons.square_grid_2x2,
                ),
                title: Text(
                  item.isPlayable
                      ? l10n.jellyfinPlayButton
                      : l10n.jellyfinBrowseButton,
                ),
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => item.isPlayable
                        ? JellyfinPlayerScreen(item: item)
                        : item.type == 'Series'
                        ? JellyfinSeriesScreen(series: item)
                        : JellyfinLibraryScreen(
                            parentId: item.id,
                            title: item.name,
                          ),
                  ),
                ),
              ),
              if (item.isPlayable)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: RemotePlaybackButton(itemId: item.id),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
