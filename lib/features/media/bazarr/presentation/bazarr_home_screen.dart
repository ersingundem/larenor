import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../../../health/data/integration_health.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/bazarr_client.dart';
import '../data/models/bazarr_wanted_item.dart';
import '../providers/bazarr_providers.dart';
import 'bazarr_connect_screen.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/service_route_status_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';

class BazarrHomeScreen extends ConsumerWidget {
  const BazarrHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(bazarrConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => ServiceRouteStatusScaffold(
        title: 'Bazarr',
        label: AppLocalizations.of(context).commonLoading,
        statusKey: const ValueKey('bazarr-home-status'),
        loading: true,
      ),
      error: (error, _) {
        if (error is DirectHomeAccessException &&
            const {
              'pending_mutation',
              'write_unconfirmed',
            }.contains(error.code)) {
          return const BazarrConnectScreen();
        }
        return ServiceRouteStatusScaffold(
          title: 'Bazarr',
          label: AppLocalizations.of(context).mediaErrorUnreachable,
          statusKey: const ValueKey('bazarr-home-status'),
          actionLabel: AppLocalizations.of(context).commonRetry,
          actionKey: const ValueKey('bazarr-home-retry'),
          onAction: () => ref.invalidate(bazarrConnectionProvider),
        );
      },
      data: (config) {
        if (config == null) return const BazarrConnectScreen();
        return const _BazarrWantedScaffold();
      },
    );
  }
}

class _BazarrWantedScaffold extends ConsumerStatefulWidget {
  const _BazarrWantedScaffold();

  @override
  ConsumerState<_BazarrWantedScaffold> createState() =>
      _BazarrWantedScaffoldState();
}

class _BazarrWantedScaffoldState
    extends MediaSessionState<_BazarrWantedScaffold> {
  bool _current(int generation, Object movies, Object episodes) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(ref.read(bazarrMissingMoviesProvider), movies) &&
      identical(ref.read(bazarrMissingEpisodesProvider), episodes);

  @override
  Widget build(BuildContext context) {
    watchMediaAccount(IntegrationId.bazarr, bazarrConnectionProvider);
    final moviesAsync = ref.watch(bazarrMissingMoviesProvider);
    final episodesAsync = ref.watch(bazarrMissingEpisodesProvider);
    final l10n = AppLocalizations.of(context);
    final generation = sessionGeneration;

    void refresh() {
      if (!_current(generation, moviesAsync, episodesAsync)) return;
      ref.invalidate(bazarrMissingMoviesProvider);
      ref.invalidate(bazarrMissingEpisodesProvider);
    }

    return ServiceRootScaffold(
      title: 'Bazarr',
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('bazarr-home-section-title'),
              container: true,
              header: true,
              child: const Text('Bazarr'),
            ),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('bazarr-home-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.commonRefresh),
                onTap: refresh,
              ),
            ],
          ),
        ),
        SliverList(
          delegate: SliverChildListDelegate([
            _WantedSection(
              title: l10n.bazarrMoviesMissingHeader,
              itemsAsync: moviesAsync,
              onChanged: refresh,
              sourceCurrent: () =>
                  _current(generation, moviesAsync, episodesAsync),
            ),
            _WantedSection(
              title: l10n.bazarrEpisodesMissingHeader,
              itemsAsync: episodesAsync,
              onChanged: refresh,
              sourceCurrent: () =>
                  _current(generation, moviesAsync, episodesAsync),
            ),
          ]),
        ),
      ],
    );
  }
}

class _WantedSection extends ConsumerWidget {
  const _WantedSection({
    required this.title,
    required this.itemsAsync,
    required this.onChanged,
    required this.sourceCurrent,
  });

  final String title;
  final AsyncValue<List<BazarrWantedItem>> itemsAsync;
  final VoidCallback onChanged;
  final bool Function() sourceCurrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return itemsAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => const Center(child: CupertinoActivityIndicator()),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          AppLocalizations.of(context).bazarrLoadSectionError(
            title,
            AppLocalizations.of(context).actionFailed,
          ),
        ),
      ),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return SettingsSection(
          header: Text(title),
          children: [
            for (final item in items)
              _WantedRow(
                item: item,
                onChanged: onChanged,
                sourceCurrent: sourceCurrent,
              ),
          ],
        );
      },
    );
  }
}

class _WantedRow extends ConsumerStatefulWidget {
  const _WantedRow({
    required this.item,
    required this.onChanged,
    required this.sourceCurrent,
  });

  final BazarrWantedItem item;
  final VoidCallback onChanged;
  final bool Function() sourceCurrent;

  @override
  ConsumerState<_WantedRow> createState() => _WantedRowState();
}

class _WantedRowState extends MediaSessionState<_WantedRow> {
  Object? _searchLease;

  bool _current(int generation, BazarrClient client) =>
      sessionCurrent(generation) &&
      widget.sourceCurrent() &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(ref.read(bazarrClientProvider), client);

  Future<void> _searchFirstMissing(BazarrClient client, int generation) async {
    final language = widget.item.missingLanguages.firstOrNull;
    if (_searchLease != null ||
        !_current(generation, client) ||
        language == null) {
      return;
    }

    final lease = Object();
    setState(() => _searchLease = lease);
    try {
      if (widget.item.isMovie) {
        await client.searchMovieSubtitle(
          radarrId: widget.item.radarrId!,
          language: language.code,
        );
      } else if (widget.item.seriesId != null &&
          widget.item.episodeId != null) {
        await client.searchEpisodeSubtitle(
          seriesId: widget.item.seriesId!,
          episodeId: widget.item.episodeId!,
          language: language.code,
        );
      }
      if (_current(generation, client)) widget.onChanged();
    } catch (_) {
      // Row simply won't update; user can retry.
    } finally {
      if (mounted && identical(_searchLease, lease)) {
        setState(() => _searchLease = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final client = ref.watch(bazarrClientProvider);
    ref.listen(bazarrClientProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        setState(() {
          sessionGeneration++;
          _searchLease = null;
        });
      }
    });
    final generation = sessionGeneration;
    final languages = widget.item.missingLanguages
        .map((l) => l.label)
        .join(', ');
    final actionKey = widget.item.isMovie
        ? ValueKey('bazarr-wanted-movie-${widget.item.radarrId}-search')
        : ValueKey(
            'bazarr-wanted-episode-${widget.item.seriesId}-${widget.item.episodeId}-search',
          );

    return SettingsActionTile(
      buttonKey: actionKey,
      leading: _searchLease != null
          ? const CupertinoActivityIndicator()
          : const Icon(CupertinoIcons.captions_bubble),
      title: Text(widget.item.title),
      additionalInfo: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            languages.isEmpty ? l10n.bazarrMissingSubtitlesLabel : languages,
          ),
          Text(l10n.commonSearch),
        ],
      ),
      onTap:
          _searchLease != null ||
              client == null ||
              widget.item.missingLanguages.isEmpty ||
              !_current(generation, client)
          ? null
          : () => _searchFirstMissing(client, generation),
    );
  }
}
