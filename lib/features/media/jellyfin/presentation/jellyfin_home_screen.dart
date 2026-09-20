import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../../../health/data/health_configuration.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/jellyfin_config.dart';
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
        return _JellyfinBrowseScaffold(config: config);
      },
    );
  }
}

class _JellyfinBrowseScaffold extends ConsumerStatefulWidget {
  const _JellyfinBrowseScaffold({required this.config});

  final JellyfinConfig config;

  @override
  ConsumerState<_JellyfinBrowseScaffold> createState() =>
      _JellyfinBrowseScaffoldState();
}

class _JellyfinBrowseScaffoldState
    extends MediaSessionState<_JellyfinBrowseScaffold> {
  bool _current(int generation) {
    final current = ref.read(jellyfinConnectionProvider);
    return sessionCurrent(generation) &&
        ModalRoute.of(context)?.isCurrent != false &&
        TickerMode.valuesOf(context).enabled &&
        !current.isLoading &&
        !current.hasError &&
        sameHealthConfiguration(current.value, widget.config);
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccounts(jellyfinOnly: true);
    final resumeAsync = ref.watch(jellyfinResumeItemsProvider);
    final latestAsync = ref.watch(jellyfinLatestItemsProvider);
    final librariesAsync = ref.watch(jellyfinLibrariesProvider);
    final l10n = AppLocalizations.of(context);
    final generation = sessionGeneration;

    return ServiceRootScaffold(
      title: 'Jellyfin',
      slivers: [
        SliverList(
          delegate: SliverChildListDelegate([
            _PosterRow(
              title: l10n.jellyfinContinueWatching,
              itemsAsync: resumeAsync,
              onOpen: (item) {
                if (!_current(generation) ||
                    !identical(
                      ref.read(jellyfinResumeItemsProvider),
                      resumeAsync,
                    )) {
                  return;
                }
                Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => JellyfinItemDetailScreen(item: item),
                  ),
                );
              },
            ),
            _PosterRow(
              title: l10n.jellyfinRecentlyAdded,
              itemsAsync: latestAsync,
              onOpen: (item) {
                if (!_current(generation) ||
                    !identical(
                      ref.read(jellyfinLatestItemsProvider),
                      latestAsync,
                    )) {
                  return;
                }
                Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => JellyfinItemDetailScreen(item: item),
                  ),
                );
              },
            ),
            _LibrarySection(
              librariesAsync: librariesAsync,
              onOpen: (library) {
                if (!_current(generation) ||
                    !identical(
                      ref.read(jellyfinLibrariesProvider),
                      librariesAsync,
                    )) {
                  return;
                }
                Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => JellyfinLibraryScreen(
                      parentId: library.id,
                      title: library.name,
                    ),
                  ),
                );
              },
            ),
            _AccountSection(
              onSettings: () {
                if (_current(generation)) {
                  context.push('/settings');
                }
              },
              onSignOut: () {
                if (_current(generation)) {
                  unawaited(
                    ref.read(jellyfinConnectionProvider.notifier).signOut(),
                  );
                }
              },
            ),
          ]),
        ),
      ],
    );
  }
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.onSettings, required this.onSignOut});

  final VoidCallback onSettings;
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
          onTap: operational ? onSettings : onSignOut,
        ),
      ],
    );
  }
}

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({required this.librariesAsync, required this.onOpen});

  final AsyncValue<List<JellyfinItem>> librariesAsync;
  final ValueChanged<JellyfinItem> onOpen;

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
        skipLoadingOnReload: false,
        skipLoadingOnRefresh: false,
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
                    onTap: () => onOpen(library),
                  ),
              ],
      ),
    );
  }
}

class _PosterRow extends StatelessWidget {
  const _PosterRow({
    required this.title,
    required this.itemsAsync,
    required this.onOpen,
  });

  final String title;
  final AsyncValue<List<JellyfinItem>> itemsAsync;
  final ValueChanged<JellyfinItem> onOpen;

  @override
  Widget build(BuildContext context) {
    if (itemsAsync.isLoading) {
      return const SizedBox(
        height: 60,
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (itemsAsync.hasError) return const SizedBox.shrink();
    final items = itemsAsync.value ?? const [];
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
                onTap: () => onOpen(item),
              );
            },
          ),
        ),
      ],
    );
  }
}
