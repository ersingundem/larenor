import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../domain/media_title.dart';
import '../../../../../shared/theme/radii.dart';

/// Wide cinematic artwork with a legible, responsive editorial overlay.
class MediaHero extends StatelessWidget {
  const MediaHero({super.key, required this.title, required this.onTap});

  final MediaTitle title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final artwork = title.backdropUrl ?? title.posterUrl;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 16),
      child: ClipRRect(
        borderRadius: Radii.brLarge,
        child: SizedBox(
          height: (wide ? 410 : 350) + (scale - 1) * 120,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF191F2A)),
              if (artwork != null)
                CachedNetworkImage(
                  imageUrl: artwork,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      Color(0x180C1018),
                      Color(0xA60C1018),
                      Color(0xFF0C1018),
                    ],
                    stops: [0, 0.5, 1],
                  ),
                ),
              ),
              Positioned(
                left: wide ? 36 : 24,
                right: wide ? 36 : 24,
                bottom: 28,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 580),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: CupertinoColors.white,
                            fontSize: wide ? 38 : 30,
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                            letterSpacing: -0.8,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          [
                            title.isTv ? l10n.mediaKindTv : l10n.mediaKindMovie,
                            if (title.year != null) '${title.year}',
                            if (title.rating != null && title.rating! > 0)
                              '★ ${title.rating!.toStringAsFixed(1)}',
                          ].join('   ·   '),
                          style: const TextStyle(
                            color: Color(0xFFD4DEE9),
                            fontSize: 13,
                          ),
                        ),
                        if (title.overview?.isNotEmpty ?? false) ...[
                          const SizedBox(height: 12),
                          Text(
                            title.overview!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFCCD2DB),
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        CupertinoButton(
                          color: CupertinoColors.white,
                          borderRadius: BorderRadius.circular(12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 12,
                          ),
                          onPressed: onTap,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                CupertinoIcons.info_circle_fill,
                                color: CupertinoColors.black,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                l10n.mediaActionDetails,
                                style: const TextStyle(
                                  color: CupertinoColors.black,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
