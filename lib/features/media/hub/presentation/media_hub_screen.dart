import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../domain/media_title.dart';
import '../domain/media_read_result.dart';
import 'widgets/media_read_issue_banner.dart';
import '../../jellyfin/presentation/jellyfin_home_screen.dart';
import '../../jellyfin/providers/jellyfin_providers.dart';
import '../../arr/providers/sonarr_providers.dart';
import '../../arr/providers/radarr_providers.dart';
import '../domain/media_identity.dart';
import 'widgets/media_theme.dart';
import '../providers/media_catalog_providers.dart';
import 'media_search_screen.dart';
import 'media_title_detail_screen.dart';
import 'widgets/media_hero.dart';
import 'widgets/media_row.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/icon_sizes.dart';
import '../../../navigation/presentation/app_shell_actions.dart';

/// One browse surface across every connected media service — the library
/// you already have and the catalogue you could request, in the same
/// place, instead of a screen per service.
class MediaHubScreen extends ConsumerStatefulWidget {
  const MediaHubScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  ConsumerState<MediaHubScreen> createState() => _MediaHubScreenState();
}

class _MediaHubScreenState extends ConsumerState<MediaHubScreen> {
  int _filter = 0;

  @override
  Widget build(BuildContext context) => MediaTheme(builder: _build);

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rowsAsync = ref.watch(mediaHubRowsProvider);

    return AppPageScaffold(
      // The nav bar lives in the scroll view rather than the scaffold so
      // it can be a large title — which means it has to wrap the loading
      // and empty states too, not just the loaded one.
      child: CustomScrollView(
        key: const PageStorageKey('media-hub'),
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.mediaHubTitle),
            trailing: widget.embedded
                ? const AppShellActions()
                : CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(context).push(
                      CupertinoPageRoute(
                        builder: (_) => const MediaSearchScreen(),
                      ),
                    ),
                    child: const Icon(CupertinoIcons.search),
                  ),
          ),
          CupertinoSliverRefreshControl(onRefresh: () => _refresh(ref)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Wrap(
                spacing: 10,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  CupertinoSlidingSegmentedControl<int>(
                    groupValue: _filter,
                    children: {
                      0: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(l10n.mediaFilterAll),
                      ),
                      1: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(l10n.mediaFilterMovies),
                      ),
                      2: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(l10n.mediaFilterTv),
                      ),
                    },
                    onValueChanged: (value) =>
                        setState(() => _filter = value ?? 0),
                  ),
                  if (ref.watch(jellyfinClientProvider) != null)
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onPressed: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const JellyfinHomeScreen(),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(CupertinoIcons.rectangle_stack, size: 18),
                          const SizedBox(width: 8),
                          Text(l10n.mediaLibraryTitle),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
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
                  message: l10n.healthReadError,
                ),
              ),
            ],
            data: (rows) => _slivers(
              context,
              l10n,
              rows
                  .map(
                    (row) => MediaRowData(
                      id: row.id,
                      titles: row.titles
                          .where(
                            (title) =>
                                _filter == 0 ||
                                title.identity.kind ==
                                    (_filter == 1
                                        ? MediaKind.movie
                                        : MediaKind.tv),
                          )
                          .toList(),
                    ),
                  )
                  .where((row) => row.titles.isNotEmpty)
                  .toList(),
              issues: rows.readIssues,
              hasSuccessfulRead: rows.successfulReads.isNotEmpty,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _slivers(
    BuildContext context,
    AppLocalizations l10n,
    List<MediaRowData> rows, {
    required List<MediaReadIssue> issues,
    required bool hasSuccessfulRead,
  }) {
    final warnings = <Widget>[
      if (issues.isNotEmpty)
        SliverToBoxAdapter(
          child: MediaReadIssueBanner(
            issues: issues,
            hasContent: rows.isNotEmpty,
            onRetry: () => _refresh(ref),
          ),
        ),
    ];
    if (rows.isEmpty) {
      if (issues.isNotEmpty) return warnings;
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _Message(
            title: hasSuccessfulRead
                ? l10n.mediaBrowseEmptyTitle
                : l10n.mediaEmptyTitle,
            message: hasSuccessfulRead
                ? l10n.mediaBrowseEmptyMessage
                : l10n.mediaEmptyMessage,
          ),
        ),
      ];
    }

    // The feature is the first thing worth featuring: something you're
    // part-way through if there is one, otherwise whatever leads the
    // first row.
    final featured = rows.first.titles.first;

    return [
      ...warnings,
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
    ref.invalidate(sonarrQueueProvider);
    ref.invalidate(radarrQueueProvider);
    ref.invalidate(mediaLibraryIndexProvider);
    ref.invalidate(mediaHubRowsProvider);
    try {
      await ref.read(mediaHubRowsProvider.future);
    } catch (_) {
      // The provider exposes the new error state; refresh callbacks must finish.
    }
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
