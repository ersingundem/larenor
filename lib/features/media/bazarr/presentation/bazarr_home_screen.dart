import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../../../health/data/integration_health.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/bazarr_client.dart';
import '../data/bazarr_subtitle_acquisition.dart';
import '../data/models/bazarr_wanted_item.dart';
import '../domain/bazarr_subtitle_request.dart';
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
  final _budget = BazarrSubtitleRequestBudget();

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
    final preferredSubtitle = ref
        .watch(bazarrPreferredSubtitleLanguageProvider)
        .value;
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
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 4),
                child: Text(
                  l10n.bazarrSearchBudget(_budget.remaining, _budget.maximum),
                  key: const ValueKey('bazarr-search-budget'),
                  style: CupertinoTheme.of(context).textTheme.textStyle
                      .copyWith(
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                ),
              ),
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
              preferredSubtitle: preferredSubtitle,
              budget: _budget,
              onBudgetChanged: () {
                if (mounted) setState(() {});
              },
            ),
            _WantedSection(
              title: l10n.bazarrEpisodesMissingHeader,
              itemsAsync: episodesAsync,
              onChanged: refresh,
              sourceCurrent: () =>
                  _current(generation, moviesAsync, episodesAsync),
              preferredSubtitle: preferredSubtitle,
              budget: _budget,
              onBudgetChanged: () {
                if (mounted) setState(() {});
              },
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
    required this.preferredSubtitle,
    required this.budget,
    required this.onBudgetChanged,
  });

  final String title;
  final AsyncValue<List<BazarrWantedItem>> itemsAsync;
  final VoidCallback onChanged;
  final bool Function() sourceCurrent;
  final String? preferredSubtitle;
  final BazarrSubtitleRequestBudget budget;
  final VoidCallback onBudgetChanged;

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
                key: ValueKey('bazarr-wanted-${item.identityKey}'),
                item: item,
                onChanged: onChanged,
                sourceCurrent: sourceCurrent,
                preferredSubtitle: preferredSubtitle,
                budget: budget,
                onBudgetChanged: onBudgetChanged,
              ),
          ],
        );
      },
    );
  }
}

class _WantedRow extends ConsumerStatefulWidget {
  const _WantedRow({
    super.key,
    required this.item,
    required this.onChanged,
    required this.sourceCurrent,
    required this.preferredSubtitle,
    required this.budget,
    required this.onBudgetChanged,
  });

  final BazarrWantedItem item;
  final VoidCallback onChanged;
  final bool Function() sourceCurrent;
  final String? preferredSubtitle;
  final BazarrSubtitleRequestBudget budget;
  final VoidCallback onBudgetChanged;

  @override
  ConsumerState<_WantedRow> createState() => _WantedRowState();
}

class _WantedRowState extends MediaSessionState<_WantedRow> {
  Object? _searchLease;
  BazarrSubtitleAcquisitionStatus? _result;
  bool _alreadyUsed = false;
  bool _quotaReached = false;

  bool _current(int generation, BazarrClient client) =>
      sessionCurrent(generation) &&
      widget.sourceCurrent() &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(ref.read(bazarrClientProvider), client);

  BazarrMissingLanguage? get _language {
    final preferred = widget.preferredSubtitle;
    if (preferred != null && preferred != 'off') {
      try {
        final expected = BazarrMissingLanguage.normalizeCode(preferred);
        for (final language in widget.item.missingLanguages) {
          final actual = BazarrMissingLanguage.normalizeCode(language.code);
          if (actual == expected ||
              actual.split('-').first == expected.split('-').first) {
            return language;
          }
        }
      } on FormatException {
        // Core and provider inputs remain untrusted at this boundary.
      }
    }
    return widget.item.missingLanguages.firstOrNull;
  }

  Future<bool> _confirm(BazarrMissingLanguage language) async {
    final l10n = AppLocalizations.of(context);
    return await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(l10n.bazarrSearchConsentTitle(language.label)),
            content: Text(l10n.bazarrSearchConsentBody),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.commonCancel),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.commonSearch),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _searchPreferred(BazarrClient client, int generation) async {
    final language = _language;
    if (_searchLease != null ||
        !_current(generation, client) ||
        language == null) {
      return;
    }

    BazarrSubtitleRequest request;
    try {
      request = BazarrSubtitleRequest.fromWanted(widget.item, language);
    } on FormatException {
      return;
    }
    if (!await _confirm(language) || !_current(generation, client)) return;
    if (widget.budget.wasReserved(request)) {
      setState(() {
        _alreadyUsed = true;
        _quotaReached = false;
      });
      return;
    }
    if (!widget.budget.reserve(request)) {
      setState(() {
        _alreadyUsed = false;
        _quotaReached = true;
      });
      return;
    }
    widget.onBudgetChanged();

    final lease = Object();
    setState(() {
      _searchLease = lease;
      _result = null;
      _alreadyUsed = false;
      _quotaReached = false;
    });
    final result = await BazarrSubtitleAcquisition(client).acquire(request);
    if (_current(generation, client) && identical(_searchLease, lease)) {
      setState(() {
        _searchLease = null;
        _result = result.status;
      });
      if (const {
        BazarrSubtitleAcquisitionStatus.confirmed,
        BazarrSubtitleAcquisitionStatus.accepted,
      }.contains(result.status)) {
        widget.onChanged();
      }
    } else if (mounted && identical(_searchLease, lease)) {
      setState(() => _searchLease = null);
    }
  }

  String? _status(AppLocalizations l10n) {
    if (_alreadyUsed) return l10n.bazarrSearchAlreadyUsed;
    if (_quotaReached) return l10n.bazarrSearchQuotaReached;
    return switch (_result) {
      BazarrSubtitleAcquisitionStatus.confirmed => l10n.bazarrSearchConfirmed,
      BazarrSubtitleAcquisitionStatus.accepted => l10n.bazarrSearchAccepted,
      BazarrSubtitleAcquisitionStatus.rejected => l10n.bazarrSearchRejected,
      BazarrSubtitleAcquisitionStatus.uncertain => l10n.bazarrSearchUncertain,
      null => null,
    };
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
          _result = null;
          _alreadyUsed = false;
          _quotaReached = false;
        });
      }
    });
    final generation = sessionGeneration;
    final languages = widget.item.missingLanguages
        .map((l) => l.label)
        .join(', ');
    final language = _language;
    BazarrSubtitleRequest? request;
    if (language != null) {
      try {
        request = BazarrSubtitleRequest.fromWanted(widget.item, language);
      } on FormatException {
        request = null;
      }
    }
    final reserved = request != null && widget.budget.wasReserved(request);
    final exhausted = widget.budget.remaining == 0;
    final status =
        _status(l10n) ??
        (reserved
            ? l10n.bazarrSearchAlreadyUsed
            : exhausted
            ? l10n.bazarrSearchQuotaReached
            : null);
    final preferred = widget.preferredSubtitle;
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
          if (preferred != null &&
              preferred != 'off' &&
              language != null &&
              language.code.split('-').first == preferred.split('-').first)
            Text(l10n.bazarrPreferredSubtitle(language.label)),
          Text(status ?? l10n.commonSearch),
        ],
      ),
      onTap:
          _searchLease != null ||
              client == null ||
              language == null ||
              request == null ||
              reserved ||
              exhausted ||
              _result != null ||
              !_current(generation, client)
          ? null
          : () => _searchPreferred(client, generation),
    );
  }
}
