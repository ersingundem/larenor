import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/action_status_indicator.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../health/data/action_receipt.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/providers/action_providers.dart';
import '../../arr/presentation/widgets/arr_add_screen.dart';
import '../../arr/providers/radarr_providers.dart';
import '../../arr/providers/sonarr_providers.dart';
import '../../bazarr/providers/bazarr_providers.dart';
import '../../data/media_api_exception.dart';
import '../../jellyfin/data/models/jellyfin_item.dart';
import '../../jellyfin/presentation/jellyfin_series_screen.dart';
import '../../jellyfin/presentation/player/jellyfin_player_screen.dart';
import '../../jellyfin/providers/jellyfin_providers.dart';
import '../../jellyseerr/data/models/jellyseerr_details.dart';
import '../../jellyseerr/providers/jellyseerr_providers.dart';
import '../../movie_night/presentation/movie_night_launcher.dart';
import '../../casting/presentation/remote_playback_button.dart';
import '../domain/media_identity.dart';
import '../domain/media_title.dart';
import '../providers/media_catalog_providers.dart';
import '../providers/media_details_providers.dart';
import 'media_session_state.dart';
import 'widgets/media_progress_card.dart';
import 'widgets/media_theme.dart';

final _jellyfinDetailProvider = FutureProvider.autoDispose
    .family<JellyfinItem?, String>((ref, id) async {
      final client = ref.watch(jellyfinClientProvider);
      if (client == null) return null;
      final item = await client.getItem(id);
      if (item.id != id) throw const FormatException('Invalid media identity');
      return ref.mounted ? item : null;
    }, retry: (_, _) => null);

class MediaTitleDetailScreen extends ConsumerStatefulWidget {
  const MediaTitleDetailScreen({super.key, required this.title});
  final MediaTitle title;
  @override
  ConsumerState<MediaTitleDetailScreen> createState() =>
      _MediaTitleDetailScreenState();
}

class _MediaTitleDetailScreenState
    extends MediaSessionState<MediaTitleDetailScreen> {
  bool _busy = false;
  String? _message;
  final _requestedSeasons = <int>{};
  bool _choosingSeasons = false;
  bool _requestSubmitted = false;

  String? get _jellyfinHint =>
      widget.title.jellyfinItemId ??
      widget.title.jellyfinSeriesId ??
      widget.title.jellyfinLookupId;

  @override
  void didUpdateWidget(MediaTitleDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldHint =
        oldWidget.title.jellyfinItemId ??
        oldWidget.title.jellyfinSeriesId ??
        oldWidget.title.jellyfinLookupId;
    if (oldWidget.title.identity.key != widget.title.identity.key ||
        oldHint != _jellyfinHint) {
      sessionGeneration++;
      clearPendingInteraction();
      _requestSubmitted = false;
    }
  }

  @override
  void clearPendingInteraction() {
    _busy = false;
    _message = null;
    _choosingSeasons = false;
    _requestedSeasons.clear();
  }

  /// Navigation snapshots provide presentation metadata only. Service-local
  /// IDs and progress are resolved again against the active account.
  MediaTitle get _title {
    final indexState = ref.read(mediaLibraryIndexProvider);
    final index = !indexState.isLoading && !indexState.hasError
        ? indexState.value
        : null;
    var freshCatalogue = false;
    var title = MediaTitle(
      identity: widget.title.identity,
      title: widget.title.title,
      year: widget.title.year,
      overview: widget.title.overview,
      rating: widget.title.rating,
      posterUrl: widget.title.posterUrl,
      backdropUrl: widget.title.backdropUrl,
      availability: MediaAvailability.unknown,
    );
    final catalogue = ref.read(
      mediaCatalogueDetailsProvider(widget.title.identity),
    );
    final seerr = ref.read(jellyseerrClientProvider);
    if (!catalogue.isLoading &&
        !catalogue.hasError &&
        catalogue.value != null &&
        seerr != null) {
      freshCatalogue = true;
      title = mediaTitleFromJellyseerr(
        catalogue.value!.result,
        posterUrl: seerr.posterUrl,
        backdropUrl: seerr.backdropUrl,
      );
    }
    if (_jellyfinHint case final String id) {
      final detail = ref.read(_jellyfinDetailProvider(id));
      final client = ref.read(jellyfinClientProvider);
      if (!detail.isLoading &&
          !detail.hasError &&
          detail.value != null &&
          client != null) {
        final item = detail.value!;
        final verified = mediaTitleFromJellyfin(
          item,
          series: index?.jellyfinItem(item.seriesId),
          imageUrl: client.imageUrl,
        );
        if (verified != null &&
            (verified.identity.isEmpty ||
                title.identity.isEmpty ||
                verified.identity.matches(title.identity))) {
          title = verified.copyWith(
            identity: title.identity.mergedWith(verified.identity),
          );
          return index?.enrich(title, preserveVerifiedPlayback: true) ?? title;
        }
      }
    }
    return index?.enrich(title, preserveVerifiedPlayback: freshCatalogue) ??
        title.copyWith(isStale: indexState.isLoading || indexState.hasError);
  }

  Future<void> _refresh() async {
    final generation = sessionGeneration;
    if (_busy || !sessionCurrent(generation)) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    ref.invalidate(mediaCatalogueDetailsProvider(widget.title.identity));
    if (_jellyfinHint case final String id) {
      ref.invalidate(_jellyfinDetailProvider(id));
    }
    ref.invalidate(sonarrQueueProvider);
    ref.invalidate(radarrQueueProvider);
    ref.invalidate(mediaLibraryIndexProvider);
    ref.invalidate(mediaHubRowsProvider);
    try {
      await ref.read(mediaLibraryIndexProvider.future);
    } catch (_) {
      if (sessionCurrent(generation)) {
        setState(
          () => _message = AppLocalizations.of(context).mediaErrorUnreachable,
        );
      }
    } finally {
      if (sessionCurrent(generation)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccounts();
    return MediaTheme(builder: _build);
  }

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!foreground || sessionExpired) {
      return AppPageScaffold(
        navigationBar: const CupertinoNavigationBar(),
        child: !foreground
            ? const SizedBox.expand()
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.mediaAccountChanged,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
      );
    }
    ref.watch(mediaLibraryIndexProvider);
    final catalogue = ref.watch(
      mediaCatalogueDetailsProvider(widget.title.identity),
    );
    if (_jellyfinHint case final String id) {
      ref.watch(_jellyfinDetailProvider(id));
    }
    final title = _title;
    final generation = sessionGeneration;
    final artwork = title.backdropUrl ?? title.posterUrl;
    final seasons =
        catalogue.value?.seasons ?? const <JellyseerrSeasonSummary>[];
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(title.title, overflow: TextOverflow.ellipsis),
        previousPageTitle: l10n.mediaHubTitle,
      ),
      child: SafeArea(
        top: false,
        child: ListView(
          children: [
            if (artwork != null)
              SizedBox(
                height: (MediaQuery.sizeOf(context).width * 9 / 16).clamp(
                  180.0,
                  380.0,
                ),
                child: CachedNetworkImage(
                  imageUrl: artwork,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => ColoredBox(
                    color: CupertinoColors.systemGrey5.resolveFrom(context),
                  ),
                ),
              ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title.title, style: AppText.title1),
                      const SizedBox(height: 4),
                      Text(
                        [
                          title.isTv ? l10n.mediaKindTv : l10n.mediaKindMovie,
                          if (title.year != null) '${title.year}',
                          if (title.rating?.isFinite == true)
                            '★ ${title.rating!.toStringAsFixed(1)}',
                        ].join(' · '),
                        style: AppText.subhead,
                      ),
                      const SizedBox(height: 16),
                      _primaryAction(title, l10n, catalogue),
                      if (title.isPlayable &&
                          !title.isStale &&
                          title.jellyfinItemId != null)
                        RemotePlaybackButton(
                          itemId: title.jellyfinItemId!,
                          enabled: !_busy,
                        ),
                      MovieNightLauncher(
                        key: ValueKey(
                          'media-movie-night:${widget.title.identity.key}:$_jellyfinHint',
                        ),
                        title: title.title,
                        enabled: title.isPlayable && !_busy,
                        isPlaybackCurrent: () => sessionCurrent(generation),
                        onPlay: _play,
                      ),
                      if (_message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _message!,
                            key: const ValueKey('media-detail-message'),
                            style: AppText.subhead,
                          ),
                        ),
                      if (catalogue.hasError)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            l10n.mediaReadPartialMessage,
                            style: AppText.footnote,
                          ),
                        ),
                      if (_choosingSeasons)
                        _seasonRequestPicker(seasons, catalogue, l10n),
                      const SizedBox(height: 20),
                      MediaProgressCard(
                        title: title,
                        onRefresh: _busy ? null : guardedMediaAction(_refresh),
                        onOpenService: (service) {
                          if (sessionCurrent(generation)) {
                            context.push('/system/${service.name}');
                          }
                        },
                      ),
                      if (seasons.isNotEmpty ||
                          title.seasonCoverage.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(l10n.mediaEpisodesTitle, style: AppText.title3),
                        _catalogueCoverage(title, seasons, l10n),
                        Text(
                          l10n.mediaCoverageUnknown,
                          style: AppText.footnote,
                        ),
                      ],
                      _subtitles(title, l10n),
                      if (title.overview?.isNotEmpty == true) ...[
                        const SizedBox(height: 20),
                        Text(
                          title.overview!,
                          style: AppText.body.copyWith(height: 1.4),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _primaryAction(
    MediaTitle title,
    AppLocalizations l10n,
    AsyncValue<JellyseerrDetails?> catalogue,
  ) {
    if (_busy) {
      return const CupertinoButton.filled(
        onPressed: null,
        child: CupertinoActivityIndicator(),
      );
    }
    final jellyfin = ref.watch(jellyfinClientProvider);
    if ((title.isPlayable || title.jellyfinSeriesId != null) &&
        !title.isStale &&
        jellyfin != null) {
      return CupertinoButton.filled(
        key: const ValueKey('media-primary-play'),
        onPressed: guardedMediaAction(_play),
        child: Text(
          title.jellyfinItemId == null
              ? l10n.mediaEpisodesTitle
              : (title.playedFraction ?? 0) > 0
              ? l10n.mediaActionResume
              : l10n.mediaActionPlay,
        ),
      );
    }
    if (_requestSubmitted) {
      return CupertinoButton.filled(
        onPressed: null,
        child: Text(l10n.mediaActionRequest),
      );
    }
    final canRequest =
        ref.watch(jellyseerrClientProvider) != null &&
        title.identity.tmdbId != null;
    if (canRequest &&
        catalogue.value != null &&
        !title.isStale &&
        !catalogue.isLoading &&
        !catalogue.hasError &&
        !{
          MediaAvailability.requested,
          MediaAvailability.downloading,
          MediaAvailability.queued,
          MediaAvailability.paused,
          MediaAvailability.importing,
          MediaAvailability.available,
        }.contains(title.availability)) {
      return CupertinoButton.filled(
        key: const ValueKey('media-primary-request'),
        onPressed: guardedMediaAction(
          title.isTv ? () => setState(() => _choosingSeasons = true) : _request,
        ),
        child: Text(
          title.isTv ? l10n.mediaRequestChooseSeasons : l10n.mediaActionRequest,
        ),
      );
    }
    final arr = title.isTv
        ? ref.watch(sonarrClientProvider)
        : ref.watch(radarrClientProvider);
    if (!canRequest &&
        arr != null &&
        !title.isStale &&
        title.availability == MediaAvailability.notAvailable) {
      return CupertinoButton.filled(
        onPressed: guardedMediaAction(_addViaArr),
        child: Text(l10n.mediaActionAdd),
      );
    }
    return Text(
      mediaAvailabilityLabel(l10n, title.availability),
      style: AppText.headline,
    );
  }

  Widget _seasonRequestPicker(
    List<JellyseerrSeasonSummary> seasons,
    AsyncValue<JellyseerrDetails?> catalogue,
    AppLocalizations l10n,
  ) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.mediaRequestChooseSeasons, style: AppText.title3),
        if (catalogue.isLoading) const CupertinoActivityIndicator(),
        if (seasons.isEmpty) Text(l10n.mediaCoverageUnknown),
        if (seasons.isNotEmpty)
          SizedBox(
            height:
                (seasons.length *
                        56.0 *
                        MediaQuery.textScalerOf(context).scale(1))
                    .clamp(80.0, 320.0),
            child: ListView.builder(
              key: const ValueKey('media-request-seasons'),
              primary: false,
              itemCount: seasons.length,
              itemBuilder: (context, index) {
                final season = seasons[index];
                return Row(
                  children: [
                    CupertinoCheckbox(
                      key: ValueKey(
                        'media-request-season-${season.seasonNumber}',
                      ),
                      value: _requestedSeasons.contains(season.seasonNumber),
                      onChanged:
                          _busy || catalogue.isLoading || catalogue.hasError
                          ? null
                          : _selectSeason(season.seasonNumber),
                    ),
                    Expanded(
                      child: Text(
                        season.name ??
                            l10n.mediaSeasonLabel(season.seasonNumber),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        CupertinoButton.filled(
          key: const ValueKey('media-confirm-request'),
          onPressed: _busy || _requestedSeasons.isEmpty
              ? null
              : guardedMediaAction(_request),
          child: Text(l10n.mediaActionRequest),
        ),
        CupertinoButton(
          onPressed: _busy
              ? null
              : guardedMediaAction(
                  () => setState(() => _choosingSeasons = false),
                ),
          child: Text(l10n.commonCancel),
        ),
      ],
    ),
  );

  ValueChanged<bool?> _selectSeason(int number) {
    final generation = sessionGeneration;
    return (selected) {
      if (!sessionCurrent(generation) || _busy) return;
      setState(() {
        if (selected == true) {
          _requestedSeasons.add(number);
        } else {
          _requestedSeasons.remove(number);
        }
      });
    };
  }

  Widget _catalogueCoverage(
    MediaTitle title,
    List<JellyseerrSeasonSummary> seasons,
    AppLocalizations l10n,
  ) {
    final catalogue = {
      for (final season in seasons) season.seasonNumber: season,
    };
    final numbers = {
      ...catalogue.keys,
      ...title.seasonCoverage.map((item) => item.seasonNumber),
    }.toList()..sort();
    return SizedBox(
      height: (numbers.length * 110.0).clamp(120.0, 400.0),
      child: ListView.builder(
        primary: false,
        key: const ValueKey('media-season-coverage'),
        itemCount: numbers.length,
        itemBuilder: (context, index) {
          final number = numbers[index];
          final season = catalogue[number];
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  season?.name ?? l10n.mediaSeasonLabel(number),
                  style: AppText.headline,
                ),
                if (season?.episodeCount != null)
                  Text(
                    l10n.mediaExpectedCount(season!.episodeCount!),
                    style: AppText.footnote,
                  ),
                for (final coverage in title.seasonCoverage.where(
                  (entry) => entry.seasonNumber == number,
                )) ...[
                  if (coverage.downloadedEpisodeCount != null)
                    Text(
                      l10n.mediaDownloadedCount(
                        coverage.downloadedEpisodeCount!,
                        mediaServiceName(coverage.source),
                      ),
                      style: AppText.footnote,
                    ),
                  if (coverage.playableEpisodeCount != null)
                    Text(
                      l10n.mediaPlayableCount(coverage.playableEpisodeCount!),
                      style: AppText.footnote,
                    ),
                  if (season?.episodeCount == null &&
                      coverage.expectedEpisodeCount != null)
                    Text(
                      l10n.mediaExpectedCount(coverage.expectedEpisodeCount!),
                      style: AppText.footnote,
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _subtitles(MediaTitle title, AppLocalizations l10n) {
    if (title.arrItemId == null) return const SizedBox.shrink();
    final wanted = title.isTv
        ? ref.watch(bazarrMissingEpisodesProvider)
        : ref.watch(bazarrMissingMoviesProvider);
    if (wanted.isLoading) return const SizedBox.shrink();
    if (wanted.hasError) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(l10n.mediaReadPartialMessage),
      );
    }
    final count =
        wanted.value
            ?.where(
              (item) => title.isTv
                  ? item.seriesId == title.arrItemId
                  : item.radarrId == title.arrItemId,
            )
            .fold<int>(0, (sum, item) => sum + item.missingLanguages.length) ??
        0;
    if (count == 0) return const SizedBox.shrink();
    return CupertinoButton(
      padding: const EdgeInsets.only(top: 16),
      onPressed: guardedMediaAction(() => context.push('/system/bazarr')),
      child: Text(l10n.mediaSubtitlesMissing(count)),
    );
  }

  /// True only when an actual player opened; browsing a series returns false.
  Future<bool> _play() async {
    final generation = sessionGeneration;
    if (_busy || !sessionCurrent(generation)) return false;
    final client = ref.read(jellyfinClientProvider);
    final title = _title;
    final itemId = title.jellyfinItemId ?? title.jellyfinSeriesId;
    if (client == null || itemId == null || title.isStale) return false;
    setState(() => _busy = true);
    var played = false;
    try {
      final item = await client.getItem(itemId);
      if (item.id != itemId) {
        throw const FormatException('Invalid media identity');
      }
      if (!mounted ||
          !sessionCurrent(generation) ||
          !identical(ref.read(jellyfinClientProvider), client)) {
        return false;
      }
      if (item.isPlayable) {
        played = true;
        await Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => JellyfinPlayerScreen(item: item),
          ),
        );
      } else if (item.type == 'Series') {
        final seasons =
            ref
                .read(mediaCatalogueDetailsProvider(title.identity))
                .value
                ?.seasons ??
            const <JellyseerrSeasonSummary>[];
        await Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => JellyfinSeriesScreen(
              series: item,
              catalogueSeasons: seasons,
              seasonCoverage: title.seasonCoverage,
            ),
          ),
        );
      } else {
        setState(
          () => _message =
              item.playbackEligibility == JellyfinPlaybackEligibility.unknown
              ? AppLocalizations.of(context).mediaStatusUnknown
              : AppLocalizations.of(context).mediaEpisodeUnavailable,
        );
      }
      if (!sessionCurrent(generation)) return played;
      ref.invalidate(_jellyfinDetailProvider(itemId));
      ref.invalidate(jellyfinResumeItemsProvider);
      ref.invalidate(mediaLibraryIndexProvider);
      ref.invalidate(mediaHubRowsProvider);
    } catch (_) {
      if (sessionCurrent(generation)) {
        setState(
          () => _message = AppLocalizations.of(context).mediaErrorUnreachable,
        );
      }
    } finally {
      if (sessionCurrent(generation)) setState(() => _busy = false);
    }
    return played;
  }

  Future<void> _request() async {
    final generation = sessionGeneration;
    if (_busy || _requestSubmitted || !sessionCurrent(generation)) return;
    final client = ref.read(jellyseerrClientProvider);
    final title = _title;
    final tmdbId = title.identity.tmdbId;
    final catalogue = ref.read(
      mediaCatalogueDetailsProvider(widget.title.identity),
    );
    if (client == null ||
        tmdbId == null ||
        title.isStale ||
        catalogue.value == null ||
        catalogue.isLoading ||
        catalogue.hasError) {
      return;
    }
    final seasons = title.isTv ? (_requestedSeasons.toList()..sort()) : null;
    if (title.isTv &&
        (seasons!.isEmpty ||
            !seasons.every(
              (number) =>
                  catalogue.value?.seasons.any(
                    (s) => s.seasonNumber == number,
                  ) ==
                  true,
            ))) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final receipt = await ref
          .read(actionControllerProvider)
          .execute<void>(
            key: ActionKey(
              integration: IntegrationId.jellyseerr,
              target: title.identity.key,
              action: 'request',
            ),
            send: () async {
              if (!sessionCurrent(generation)) {
                throw StateError('Media account changed');
              }
              await client.requestMedia(
                mediaType: title.isTv ? 'tv' : 'movie',
                mediaId: tmdbId,
                seasons: seasons,
              );
            },
            classifyFailure: (error) => switch (error) {
              MediaApiException(statusCode: 401) =>
                ActionFailure.authentication,
              MediaApiException(statusCode: 403) => ActionFailure.permission,
              MediaApiException(statusCode: final int code)
                  when code >= 400 && code < 500 =>
                ActionFailure.rejected,
              _ => ActionFailure.unknown,
            },
          );
      if (!sessionCurrent(generation)) return;
      if (receipt.status == ActionStatus.unknown) _requestSubmitted = true;
      if (receipt.status != ActionStatus.accepted &&
          receipt.status != ActionStatus.confirmed) {
        throw ActionExecutionException(receipt);
      }
      setState(() {
        _requestSubmitted = true;
        _message = l10n.mediaRequestAccepted;
        _choosingSeasons = false;
        _requestedSeasons.clear();
      });
      ref.invalidate(mediaCatalogueDetailsProvider(widget.title.identity));
      ref.invalidate(jellyseerrMyRequestsProvider);
      ref.invalidate(mediaLibraryIndexProvider);
      ref.invalidate(mediaHubRowsProvider);
      ref.invalidate(mediaSearchProvider);
    } catch (error) {
      if (sessionCurrent(generation)) {
        setState(() => _message = actionErrorLabel(l10n, error));
      }
    } finally {
      if (sessionCurrent(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _addViaArr() async {
    final generation = sessionGeneration;
    if (_busy || !sessionCurrent(generation)) return;
    final title = _title;
    final client = title.isTv
        ? ref.read(sonarrClientProvider)
        : ref.read(radarrClientProvider);
    if (client == null || title.isStale) return;
    final l10n = AppLocalizations.of(context);
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ArrAddScreen(
          sourceCurrent: () => sessionCurrent(generation),
          integration: title.isTv ? IntegrationId.sonarr : IntegrationId.radarr,
          connectionProvider: title.isTv
              ? sonarrConnectionProvider
              : radarrConnectionProvider,
          title: l10n.mediaActionAdd,
          searchHint: title.title,
          initialQuery: title.isTv && title.identity.tvdbId != null
              ? 'tvdb:${title.identity.tvdbId}'
              : !title.isTv && title.identity.tmdbId != null
              ? 'tmdb:${title.identity.tmdbId}'
              : title.title,
          onLookup: client.lookup,
          loadQualityProfiles: client.getQualityProfiles,
          loadRootFolders: client.getRootFolders,
          onAdd: (result, quality, folder, metadata) async {
            if (!sessionCurrent(generation)) {
              throw StateError('Media account changed');
            }
            await client.add(
              result: result,
              qualityProfileId: quality,
              rootFolderPath: folder,
              metadataProfileId: metadata,
            );
          },
        ),
      ),
    );
    if (!sessionCurrent(generation)) return;
    await _refresh();
  }
}

MediaTitle bareMediaTitle(MediaIdentity identity, String title) => MediaTitle(
  identity: identity,
  title: title,
  availability: MediaAvailability.notAvailable,
);
