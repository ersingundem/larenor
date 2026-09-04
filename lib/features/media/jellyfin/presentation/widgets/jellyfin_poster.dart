import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../shared/widgets/poster_card.dart';
import '../../data/models/jellyfin_item.dart';
import '../../providers/jellyfin_providers.dart';

/// A Jellyfin library item as a poster. Thin wrapper over [PosterCard] —
/// its only job is resolving the artwork URL from the client.
class JellyfinPoster extends ConsumerWidget {
  const JellyfinPoster({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 120,
  });

  final JellyfinItem item;
  final VoidCallback onTap;
  final double width;

  static double heightFor(double width, BuildContext context) =>
      PosterCard.heightFor(width, context);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(jellyfinClientProvider);

    return PosterCard(
      title: item.name,
      // Tagging the URL makes it content-addressed, so the on-disk cache
      // can hold a poster indefinitely and still pick up real artwork
      // changes.
      imageUrl: client?.imageUrl(item.id, tag: item.imageTags?['Primary']),
      onTap: onTap,
      width: width,
      progress: item.playedFraction > 0 ? item.playedFraction : null,
    );
  }
}
