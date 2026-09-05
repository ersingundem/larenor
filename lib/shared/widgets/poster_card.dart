import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';

import '../theme/radii.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// A 2:3 poster with a caption underneath, shared by every poster row in
/// the app.
///
/// It exists mainly so [heightFor] does: a horizontal poster row has to be
/// given a bounded height, and both rows previously hardcoded one that was
/// too small — the Jellyfin row clipped its own captions at the default
/// text size. Deriving the height from the same constants that lay the
/// card out means the two can't drift apart again.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    required this.onTap,
    this.imageUrl,
    this.width = 128,
    this.progress,
    this.progressColor,
    this.overlay,
  });

  final String title;
  final VoidCallback onTap;
  final String? imageUrl;
  final double width;

  /// 0–1, drawn as a bar across the bottom of the artwork.
  final double? progress;
  final Color? progressColor;

  /// Drawn in the artwork's top-right corner, e.g. an availability badge.
  final Widget? overlay;

  static const _captionGap = Gap.sm;
  static const _focusInset = 4.0;

  /// The total height a [PosterCard] of [width] occupies, including its
  /// caption line. Row containers should use this rather than a literal.
  static double heightFor(double width, BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final captionHeight = scaler.scale(AppText.posterCaption.fontSize!) * 1.4;
    return (width - _focusInset * 2) * 1.5 +
        _captionGap +
        captionHeight +
        _focusInset * 2;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    return SizedBox(
      width: width,
      // Native focus extends outside the button; keep it inside row/grid clips.
      child: Padding(
        padding: const EdgeInsets.all(_focusInset),
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(48),
          borderRadius: Radii.brArtwork,
          focusColor: CupertinoTheme.brightnessOf(context) == Brightness.dark
              ? Color.lerp(theme.primaryColor, CupertinoColors.white, .12)
              : theme.primaryColor,
          onPressed: onTap,
          child: DefaultTextStyle(
            style: DefaultTextStyle.of(context).style,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: Radii.brArtwork,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _Artwork(url: imageUrl),
                        if (overlay != null)
                          Positioned(top: 6, right: 6, child: overlay!),
                        if (progress != null && progress! > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _ProgressBar(
                              value: progress!,
                              color:
                                  progressColor ??
                                  CupertinoTheme.of(context).primaryColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: _captionGap),
                // Flexible so a caption that grows with the system text size
                // shortens the card rather than overflowing it.
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.posterCaption,
                  ),
                ),
              ],
            ),
          ),
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
