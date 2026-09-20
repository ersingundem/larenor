import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
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

    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(title)),
      child: SafeArea(
        child: itemsAsync.when(
          loading: () => _LibraryStatus(
            label: AppLocalizations.of(context).commonLoading,
            loading: true,
          ),
          error: (_, _) => _LibraryStatus(
            label: AppLocalizations.of(context).mediaErrorUnreachable,
          ),
          data: (items) {
            if (items.isEmpty) {
              return _LibraryStatus(
                label: AppLocalizations.of(context).jellyfinLibraryEmpty,
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

/// The browse flow uses the same private, live status contract as the media
/// hub: backend diagnostics stay out of the UI and TalkBack gets one update.
class _LibraryStatus extends StatelessWidget {
  const _LibraryStatus({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      key: const ValueKey('jellyfin-library-status'),
      label: label,
      liveRegion: true,
      excludeSemantics: true,
      child: loading
          ? const CupertinoActivityIndicator()
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Text(label, textAlign: TextAlign.center),
            ),
    ),
  );
}
