import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/jellyfin_providers.dart';
import 'jellyfin_item_detail_screen.dart';
import 'widgets/jellyfin_poster.dart';

/// Shows the contents of a Jellyfin library or folder. Tapping a playable
/// item (Movie/Episode) or a container (Series/Season/folder) both push
/// [JellyfinItemDetailScreen], which then either offers Play or a further
/// "Browse" step into this same screen — a simple recursive drill-down.
class JellyfinLibraryScreen extends ConsumerWidget {
  const JellyfinLibraryScreen({
    super.key,
    required this.parentId,
    required this.title,
  });

  final String parentId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(jellyfinLibraryItemsProvider(parentId));

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(title)),
      child: SafeArea(
        child: itemsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (items) {
            if (items.isEmpty) {
              return const Center(child: Text('Nothing here yet'));
            }
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.62,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return JellyfinPoster(
                  item: item,
                  width: double.infinity,
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => JellyfinItemDetailScreen(item: item),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
