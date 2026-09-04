import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../domain/media_title.dart';
import '../../../../../shared/theme/spacing.dart';
import '../../../../../shared/theme/typography.dart';
import '../../../../../shared/theme/icon_sizes.dart';

/// The full-bleed feature at the top of the hub.
class MediaHero extends StatelessWidget {
  const MediaHero({super.key, required this.title, required this.onTap});

  final MediaTitle title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final artwork = title.backdropUrl ?? title.posterUrl;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: 260,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (artwork != null)
              CachedNetworkImage(
                imageUrl: artwork,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => ColoredBox(
                  color: CupertinoColors.systemGrey5.resolveFrom(context),
                ),
              )
            else
              ColoredBox(
                color: CupertinoColors.systemGrey5.resolveFrom(context),
              ),
            // Keeps the title legible over an arbitrary backdrop.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x66000000),
                    Color(0xCC000000),
                  ],
                  stops: [0.35, 0.7, 1],
                ),
              ),
            ),
            Positioned(
              left: Insets.pageGutter,
              right: Insets.pageGutter,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.title1.copyWith(
                      color: CupertinoColors.white,
                    ),
                  ),
                  if (title.year != null) ...[
                    const SizedBox(height: Gap.xxs),
                    Text(
                      '${title.year}',
                      style: AppText.footnote.copyWith(
                        color: CupertinoColors.systemGrey3.resolveFrom(context),
                      ),
                    ),
                  ],
                  const SizedBox(height: Gap.md),
                  CupertinoButton.filled(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Gap.xxl,
                      vertical: Gap.sm,
                    ),
                    onPressed: onTap,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          title.isPlayable
                              ? CupertinoIcons.play_fill
                              : CupertinoIcons.info,
                          size: IconSizes.caption,
                        ),
                        const SizedBox(width: Gap.sm),
                        Text(
                          title.isPlayable
                              ? l10n.mediaActionPlay
                              : l10n.mediaActionDetails,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
