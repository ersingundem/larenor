import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';

import '../../domain/media_title.dart';
import 'availability_badge.dart';

/// A poster card for any title, whatever service it came from.
///
/// Deliberately URL-driven rather than tied to one service's item model
/// (the way the older Jellyfin-only poster was), so a single row can mix
/// library items, discover results and calendar entries.
class MediaPoster extends StatelessWidget {
  const MediaPoster({
    super.key,
    required this.title,
    required this.onTap,
    this.width = 128,
  });

  final MediaTitle title;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final progress = title.playedFraction ?? title.downloadProgress;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Artwork(url: title.posterUrl),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: AvailabilityBadge(
                        availability: title.availability,
                      ),
                    ),
                    if (progress != null && progress > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _ProgressBar(
                          value: progress,
                          // Watch progress and download progress are
                          // different things; colouring them apart keeps
                          // a half-watched film from reading as a
                          // half-finished download.
                          color: title.playedFraction != null
                              ? CupertinoColors.systemRed
                              : CupertinoColors.systemBlue,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: CupertinoColors.systemGrey5.resolveFrom(context),
      child: Center(
        child: Icon(
          CupertinoIcons.film,
          color: CupertinoColors.systemGrey.resolveFrom(context),
        ),
      ),
    );

    final url = this.url;
    if (url == null || url.isEmpty) return placeholder;

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, _) =>
          ColoredBox(color: CupertinoColors.systemGrey5.resolveFrom(context)),
      errorWidget: (_, _, _) => placeholder,
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 3,
      color: CupertinoColors.black.withValues(alpha: 0.35),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: value.clamp(0.0, 1.0),
        child: ColoredBox(color: CupertinoDynamicColor.resolve(color, context)),
      ),
    );
  }
}
