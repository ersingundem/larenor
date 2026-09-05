import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
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
          error: (error, _) => Center(
            child: Text(
              AppLocalizations.of(context).adminLoadError(error.toString()),
            ),
          ),
          data: (items) {
            if (items.isEmpty) {
              return Center(
                child: Text(AppLocalizations.of(context).jellyfinLibraryEmpty),
              );
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 12.0;
                const maxWidth = 140.0;
                final usableWidth = constraints.maxWidth - spacing * 2;
                final columns = math.max(
                  1,
                  (usableWidth / (maxWidth + spacing)).ceil(),
                );
                final posterWidth =
                    (usableWidth - spacing * (columns - 1)) / columns;
                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    mainAxisExtent: JellyfinPoster.heightFor(
                      posterWidth,
                      context,
                    ),
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
            );
          },
        ),
      ),
    );
  }
}
