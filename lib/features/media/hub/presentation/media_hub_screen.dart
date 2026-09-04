import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../domain/media_title.dart';
import '../providers/media_catalog_providers.dart';
import 'media_search_screen.dart';
import 'media_title_detail_screen.dart';
import 'widgets/media_hero.dart';
import 'widgets/media_row.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/icon_sizes.dart';

/// One browse surface across every connected media service — the library
/// you already have and the catalogue you could request, in the same
/// place, instead of a screen per service.
class MediaHubScreen extends ConsumerWidget {
  const MediaHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final rowsAsync = ref.watch(mediaHubRowsProvider);

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      // The nav bar lives in the scroll view rather than the scaffold so
      // it can be a large title — which means it has to wrap the loading
      // and empty states too, not just the loaded one.
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.mediaHubTitle),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute(builder: (_) => const MediaSearchScreen()),
              ),
              child: const Icon(CupertinoIcons.search),
            ),
          ),
          CupertinoSliverRefreshControl(onRefresh: () => _refresh(ref)),
          ...rowsAsync.when(
            loading: () => const [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CupertinoActivityIndicator()),
              ),
            ],
            error: (error, _) => [
              SliverFillRemaining(
                hasScrollBody: false,
                child: _Message(
                  title: l10n.commonError,
                  message: error.toString(),
                ),
              ),
            ],
            data: (rows) => _slivers(context, l10n, rows),
          ),
        ],
      ),
    );
  }

  List<Widget> _slivers(
    BuildContext context,
    AppLocalizations l10n,
    List<MediaRowData> rows,
  ) {
    if (rows.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _Message(
            title: l10n.mediaEmptyTitle,
            message: l10n.mediaEmptyMessage,
          ),
        ),
      ];
    }

    // The feature is the first thing worth featuring: something you're
    // part-way through if there is one, otherwise whatever leads the
    // first row.
    final featured = rows.first.titles.first;

    return [
      SliverToBoxAdapter(
        child: MediaHero(
          title: featured,
          onTap: () => openMediaTitle(context, featured),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final row = rows[index];
          return MediaRow(
            title: _rowTitle(l10n, row.id),
            titles: row.titles,
            onTapTitle: (title) => openMediaTitle(context, title),
          );
        }, childCount: rows.length),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: Gap.xxxl)),
    ];
  }

  String _rowTitle(AppLocalizations l10n, MediaRowId id) => switch (id) {
    MediaRowId.continueWatching => l10n.mediaRowContinueWatching,
    MediaRowId.recentlyAdded => l10n.mediaRowRecentlyAdded,
    MediaRowId.trending => l10n.mediaRowTrending,
    MediaRowId.comingSoon => l10n.mediaRowComingSoon,
    MediaRowId.downloading => l10n.mediaRowDownloading,
  };

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(mediaLibraryIndexProvider);
    ref.invalidate(mediaHubRowsProvider);
    await ref.read(mediaHubRowsProvider.future);
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: Insets.emptyState,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.film,
              size: IconSizes.hero,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
            const SizedBox(height: 16),
            Text(title, style: AppText.emptyStateTitle),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppText.emptyStateBody.copyWith(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void openMediaTitle(BuildContext context, MediaTitle title) {
  Navigator.of(context).push(
    CupertinoPageRoute(builder: (_) => MediaTitleDetailScreen(title: title)),
  );
}
