import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../domain/server_music_manager_models.dart';

class ServerMusicLongformCard extends StatelessWidget {
  const ServerMusicLongformCard({
    super.key,
    required this.catalog,
    required this.failure,
    required this.busy,
    required this.onRetry,
  });

  final ServerMusicLongformCatalog? catalog;
  final String? failure;
  final bool busy;
  final VoidCallback? onRetry;

  String _duration(double seconds) {
    final minutes = (seconds / 60).floor();
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return hours == 0 ? '${rest}m' : '${hours}h ${rest}m';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = catalog?.items ?? const <ServerMusicLongformItem>[];
    return Container(
      key: const ValueKey('music-longform-card'),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(l.serverMusicLongformTitle, style: AppText.headline),
          ),
          const SizedBox(height: 8),
          Text(l.serverMusicLongformIntro),
          if (busy) ...[
            const SizedBox(height: 20),
            const Center(child: CupertinoActivityIndicator()),
          ] else if (failure != null) ...[
            const SizedBox(height: 20),
            Semantics(
              key: const ValueKey('music-longform-error'),
              liveRegion: true,
              child: Text(l.serverMusicLongformError),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: CupertinoButton(
                key: const ValueKey('music-longform-retry'),
                minimumSize: const Size(48, 48),
                onPressed: onRetry,
                child: Text(l.commonRetry),
              ),
            ),
          ] else if (items.isEmpty) ...[
            const SizedBox(height: 20),
            Semantics(
              key: const ValueKey('music-longform-empty'),
              liveRegion: true,
              child: Text(l.serverMusicLongformEmpty),
            ),
          ] else ...[
            const SizedBox(height: 12),
            for (var index = 0; index < items.length; index++) ...[
              if (index > 0) const SizedBox(height: 12),
              _LongformItem(
                key: ValueKey('music-longform-item-$index'),
                item: items[index],
                duration: _duration,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _LongformItem extends StatelessWidget {
  const _LongformItem({super.key, required this.item, required this.duration});

  final ServerMusicLongformItem item;
  final String Function(double) duration;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final percent = (item.progress * 100).round();
    final chapter = item.currentChapter;
    final type = item.mediaType == 'audiobook'
        ? l.serverMusicLongformAudiobook
        : l.serverMusicLongformPodcastEpisode;
    final details = <String>[
      '$type, ${l.serverMusicLongformProgress}: $percent%',
      '${duration(item.resumePositionSeconds)} / ${duration(item.durationSeconds)}',
      if (chapter != null) '${l.serverMusicLongformChapter}: ${chapter.name}',
    ];
    return Semantics(
      container: true,
      label: '${item.name}. ${details.join('. ')}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: CupertinoColors.tertiarySystemGroupedBackground.resolveFrom(
              context,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.headline,
              ),
              const SizedBox(height: 8),
              Text(details.first),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      Container(
                        height: 10,
                        color: CupertinoColors.systemGrey5.resolveFrom(context),
                      ),
                      Container(
                        width: constraints.maxWidth * item.progress,
                        height: 10,
                        color: CupertinoColors.activeBlue.resolveFrom(context),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(details[1]),
              if (chapter != null) ...[
                const SizedBox(height: 4),
                Text(details[2], maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
