import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../data/models/jellyfin_item.dart';
import '../providers/jellyfin_providers.dart';
import 'jellyfin_connect_screen.dart';
import 'jellyfin_item_detail_screen.dart';
import 'jellyfin_library_screen.dart';
import 'widgets/jellyfin_poster.dart';
import '../../../../shared/widgets/section_header.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/operational_service_scope.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';

class JellyfinHomeScreen extends ConsumerWidget {
  const JellyfinHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(jellyfinConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => _JellyfinRouteStatus(
        label: AppLocalizations.of(context).commonLoading,
        loading: true,
      ),
      error: (error, _) =>
          error is DirectHomeAccessException &&
              const {
                'pending_mutation',
                'write_unconfirmed',
              }.contains(error.code)
          ? const JellyfinConnectScreen()
          : _JellyfinRouteStatus(
              label: AppLocalizations.of(context).mediaErrorUnreachable,
              onRetry: () => ref.invalidate(jellyfinConnectionProvider),
            ),
      data: (config) {
        if (config == null) return const JellyfinConnectScreen();
        return _JellyfinBrowseScaffold(ref: ref);
      },
    );
  }
}

class _JellyfinRouteStatus extends StatelessWidget {
  const _JellyfinRouteStatus({
    required this.label,
    this.loading = false,
    this.onRetry,
  });

  final String label;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Jellyfin')),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                key: const ValueKey('jellyfin-home-status'),
                label: label,
                liveRegion: true,
                excludeSemantics: true,
                child: loading
                    ? const CupertinoActivityIndicator()
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(label, textAlign: TextAlign.center),
                      ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  label: l10n.commonRetry,
                  child: CupertinoButton(
                    key: const ValueKey('jellyfin-home-retry'),
                    minimumSize: const Size(48, 48),
                    onPressed: onRetry,
                    child: ExcludeSemantics(child: Text(l10n.commonRetry)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _JellyfinBrowseScaffold extends ConsumerWidget {
  const _JellyfinBrowseScaffold({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context, WidgetRef _) {
    final resumeAsync = ref.watch(jellyfinResumeItemsProvider);
    final latestAsync = ref.watch(jellyfinLatestItemsProvider);
    final librariesAsync = ref.watch(jellyfinLibrariesProvider);

    return ServiceRootScaffold(
      title: 'Jellyfin',
      trailing: ServiceAccountAction(
        onSignOut: () =>
            ref.read(jellyfinConnectionProvider.notifier).signOut(),
      ),
      slivers: [
        SliverList(
          delegate: SliverChildListDelegate([
            _PosterRow(
              title: AppLocalizations.of(context).jellyfinContinueWatching,
              itemsAsync: resumeAsync,
            ),
            _PosterRow(
              title: AppLocalizations.of(context).jellyfinRecentlyAdded,
              itemsAsync: latestAsync,
            ),
            SectionHeader(
              title: AppLocalizations.of(context).jellyfinLibrariesHeader,
            ),
            librariesAsync.when(
              loading: () => const Center(child: CupertinoActivityIndicator()),
              error: (error, _) => Text(
                AppLocalizations.of(context).adminLoadError(error.toString()),
              ),
              data: (libraries) => libraries.isEmpty
                  ? Text(AppLocalizations.of(context).jellyfinLibraryEmpty)
                  : CupertinoListSection.insetGrouped(
                      children: [
                        for (final library in libraries)
                          CupertinoListTile(
                            leading: const Icon(CupertinoIcons.square_stack),
                            title: Text(library.name),
                            trailing: const CupertinoListTileChevron(),
                            onTap: () => Navigator.of(context).push(
                              CupertinoPageRoute(
                                builder: (_) => JellyfinLibraryScreen(
                                  parentId: library.id,
                                  title: library.name,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ]),
        ),
      ],
    );
  }
}

class _PosterRow extends StatelessWidget {
  const _PosterRow({required this.title, required this.itemsAsync});

  final String title;
  final AsyncValue<List<JellyfinItem>> itemsAsync;

  @override
  Widget build(BuildContext context) {
    final items = itemsAsync.value ?? const [];
    if (itemsAsync.isLoading && items.isEmpty) {
      return const SizedBox(
        height: 60,
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: JellyfinPoster.heightFor(120, context),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = items[index];
              return JellyfinPoster(
                item: item,
                onTap: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => JellyfinItemDetailScreen(item: item),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
