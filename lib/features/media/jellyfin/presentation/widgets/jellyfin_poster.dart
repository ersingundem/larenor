import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/jellyfin_item.dart';
import '../../providers/jellyfin_providers.dart';

/// A poster tile with title, tappable to open [onTap]. Falls back to a
/// placeholder icon when the item has no image or it fails to load.
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(jellyfinClientProvider);
    final imageUrl = client?.imageUrl(item.id);

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: CupertinoColors.systemGrey5.resolveFrom(context),
                      child: imageUrl == null
                          ? const Icon(CupertinoIcons.film)
                          : Image.network(
                              imageUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const Icon(CupertinoIcons.film),
                            ),
                    ),
                    if (item.playedFraction > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          height: 3,
                          color: CupertinoColors.black.withValues(alpha: 0.4),
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: item.playedFraction.clamp(0.0, 1.0),
                            child: Container(
                              color: CupertinoTheme.of(context).primaryColor,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
