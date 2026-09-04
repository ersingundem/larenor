import 'package:flutter/cupertino.dart';

import '../../../../../shared/widgets/poster_card.dart';
import '../../domain/media_title.dart';
import 'availability_badge.dart';

/// A poster for any title, whatever service it came from — the hub's rows
/// mix library items, discover results and calendar entries freely.
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

  static double heightFor(double width, BuildContext context) =>
      PosterCard.heightFor(width, context);

  @override
  Widget build(BuildContext context) {
    return PosterCard(
      title: title.title,
      imageUrl: title.posterUrl,
      onTap: onTap,
      width: width,
      progress: title.playedFraction ?? title.downloadProgress,
      // Watch progress and download progress are different things;
      // colouring them apart stops a half-watched film reading as a
      // half-finished download.
      progressColor: title.playedFraction != null
          ? CupertinoColors.systemRed
          : CupertinoColors.systemBlue,
      overlay: AvailabilityBadge(availability: title.availability),
    );
  }
}
