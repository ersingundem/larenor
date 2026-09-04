import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../domain/media_title.dart';
import '../providers/media_catalog_providers.dart';
import 'media_search_screen.dart';
import 'media_title_detail_screen.dart';
import 'widgets/media_hero.dart';
import 'widgets/media_row.dart';

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
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.mediaHubTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(
            context,
          ).push(CupertinoPageRoute(builder: (_) => const MediaSearchScreen())),
          child: const Icon(CupertinoIcons.search),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: rowsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) =>
              _Message(title: l10n.commonError, message: error.toString()),
          data: (rows) => _Body(rows: rows, onRefresh: () => _refresh(ref)),
        ),
      ),
    );
  }

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(mediaLibraryIndexProvider);
    ref.invalidate(mediaHubRowsProvider);
    await ref.read(mediaHubRowsProvider.future);
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.rows, required this.onRefresh});

  final List<MediaRowData> rows;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (rows.isEmpty) {
      return _Message(
        title: l10n.mediaEmptyTitle,
        message: l10n.mediaEmptyMessage,
      );
    }

    // The feature is the first thing worth featuring: something you're
    // part-way through if there is one, otherwise whatever leads the
    // first row.
    final featured = rows.first.titles.first;

    return CustomScrollView(
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: onRefresh),
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
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  String _rowTitle(AppLocalizations l10n, MediaRowId id) => switch (id) {
    MediaRowId.continueWatching => l10n.mediaRowContinueWatching,
    MediaRowId.recentlyAdded => l10n.mediaRowRecentlyAdded,
    MediaRowId.trending => l10n.mediaRowTrending,
    MediaRowId.comingSoon => l10n.mediaRowComingSoon,
    MediaRowId.downloading => l10n.mediaRowDownloading,
  };
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.film,
              size: 44,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
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
