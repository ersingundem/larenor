import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../data/models/jellyfin_item.dart';
import '../providers/jellyfin_providers.dart';
import 'jellyfin_connect_screen.dart';
import 'jellyfin_item_detail_screen.dart';
import 'jellyfin_library_screen.dart';
import 'widgets/jellyfin_poster.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/section_header.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/operational_service_scope.dart';
import '../../../../shared/widgets/service_route_status_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';

class JellyfinHomeScreen extends ConsumerWidget {
  const JellyfinHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(jellyfinConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => ServiceRouteStatusScaffold(
        title: 'Jellyfin',
        label: AppLocalizations.of(context).commonLoading,
        statusKey: const ValueKey('jellyfin-home-status'),
        loading: true,
      ),
      error: (error, _) =>
          error is DirectHomeAccessException &&
              const {
                'pending_mutation',
                'write_unconfirmed',
              }.contains(error.code)
          ? const JellyfinConnectScreen()
          : ServiceRouteStatusScaffold(
              title: 'Jellyfin',
              label: AppLocalizations.of(context).mediaErrorUnreachable,
              statusKey: const ValueKey('jellyfin-home-status'),
              actionLabel: AppLocalizations.of(context).commonRetry,
              actionKey: const ValueKey('jellyfin-home-retry'),
              onAction: () => ref.invalidate(jellyfinConnectionProvider),
            ),
      data: (config) {
        if (config == null) return const JellyfinConnectScreen();
        return _JellyfinBrowseScaffold(ref: ref);
      },
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
    final l10n = AppLocalizations.of(context);

    return ServiceRootScaffold(
      title: 'Jellyfin',
      slivers: [
        SliverList(
          delegate: SliverChildListDelegate([
            _PosterRow(
              title: l10n.jellyfinContinueWatching,
              itemsAsync: resumeAsync,
            ),
            _PosterRow(
              title: l10n.jellyfinRecentlyAdded,
              itemsAsync: latestAsync,
            ),
            _LibrarySection(librariesAsync: librariesAsync),
            _AccountSection(
              onSignOut: () =>
                  ref.read(jellyfinConnectionProvider.notifier).signOut(),
            ),
          ]),
        ),
      ],
    );
  }
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final operational = OperationalServiceScope.isOperational(context);
    return SettingsSection(
      children: [
        SettingsActionTile(
          buttonKey: const ValueKey('service-account-action'),
          leading: Icon(
            operational
                ? CupertinoIcons.settings
                : CupertinoIcons.square_arrow_right,
          ),
          title: Text(
            operational ? l10n.settingsScreenTitle : l10n.commonSignOut,
          ),
          onTap: operational ? () => context.push('/settings') : onSignOut,
        ),
      ],
    );
  }
}

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({required this.librariesAsync});

  final AsyncValue<List<JellyfinItem>> librariesAsync;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SettingsSection(
      header: Semantics(
        container: true,
        header: true,
        child: Text(l10n.jellyfinLibrariesHeader),
      ),
      children: librariesAsync.when(
        loading: () => const [
          Padding(
            padding: Insets.tile,
            child: Center(child: CupertinoActivityIndicator()),
          ),
        ],
        error: (_, _) => [
          Padding(padding: Insets.tile, child: Text(l10n.healthReadError)),
        ],
        data: (libraries) => libraries.isEmpty
            ? [
                Padding(
                  padding: Insets.tile,
                  child: Text(l10n.jellyfinLibraryEmpty),
                ),
              ]
            : [
                for (final library in libraries)
                  SettingsActionTile(
                    buttonKey: ValueKey('jellyfin-library-${library.id}'),
                    leading: const Icon(CupertinoIcons.square_stack),
                    title: Text(library.name),
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
            padding: Insets.page,
            itemCount: items.length,
            separatorBuilder: (_, _) => Gap.hMd,
            itemBuilder: (context, index) {
              final item = items[index];
              return JellyfinPoster(
                key: ValueKey('jellyfin-poster-${item.id}'),
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
