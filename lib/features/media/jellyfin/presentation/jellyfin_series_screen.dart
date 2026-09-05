import '../../casting/presentation/remote_playback_button.dart';

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../hub/domain/media_title.dart';
import '../../hub/presentation/media_session_state.dart';
import '../../hub/presentation/widgets/media_theme.dart';
import '../../hub/providers/media_catalog_providers.dart';
import '../../jellyseerr/data/models/jellyseerr_details.dart';
import '../data/models/jellyfin_item.dart';
import '../providers/jellyfin_providers.dart';
import 'player/jellyfin_player_screen.dart';

/// Browse the episodes this account reports, keeping catalogue and file
/// coverage separate from Jellyfin playback eligibility.
class JellyfinSeriesScreen extends ConsumerStatefulWidget {
  const JellyfinSeriesScreen({
    super.key,
    required this.series,
    this.catalogueSeasons = const [],
    this.seasonCoverage = const [],
  });
  final JellyfinItem series;
  final List<JellyseerrSeasonSummary> catalogueSeasons;
  final List<MediaSeasonCoverage> seasonCoverage;
  @override
  ConsumerState<JellyfinSeriesScreen> createState() =>
      _JellyfinSeriesScreenState();
}

class _Season {
  const _Season({required this.key, this.number, this.item, this.catalogue});
  final String key;
  final int? number;
  final JellyfinItem? item;
  final JellyseerrSeasonSummary? catalogue;
}

class _JellyfinSeriesScreenState
    extends MediaSessionState<JellyfinSeriesScreen> {
  List<_Season> _seasons = const [];
  List<JellyfinItem> _episodes = const [];
  _Season? _season;
  bool _loading = false;
  bool _playing = false;
  bool _readFailed = false;
  String? _playError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void clearPendingInteraction() {
    _loading = false;
    _playing = false;
    _playError = null;
  }

  @override
  void resumeMediaSession() {
    if (!sessionExpired) unawaited(_load());
  }

  List<_Season> _mergeSeasons(List<JellyfinItem> items) {
    final indexed = <String, _Season>{};
    for (final metadata in widget.catalogueSeasons) {
      final key = 'number:${metadata.seasonNumber}';
      indexed[key] = _Season(
        key: key,
        number: metadata.seasonNumber,
        catalogue: metadata,
      );
    }
    for (final item in items) {
      final number = item.indexNumber;
      final key = number == null ? 'id:${item.id}' : 'number:$number';
      indexed[key] = _Season(
        key: key,
        number: number,
        item: item,
        catalogue: indexed[key]?.catalogue,
      );
    }
    return indexed.values.toList()..sort((a, b) {
      if (a.number == null) {
        return b.number == null ? a.key.compareTo(b.key) : 1;
      }
      if (b.number == null) return -1;
      return a.number!.compareTo(b.number!);
    });
  }

  Future<void> _load({_Season? selected}) async {
    final generation = sessionGeneration;
    if (_loading || !sessionCurrent(generation)) return;
    setState(() {
      _loading = true;
      _readFailed = false;
      _playError = null;
    });
    try {
      final client = ref.read(jellyfinClientProvider);
      if (client == null) throw StateError('Media connection unavailable');
      // Always reread season metadata: new seasons can appear between refreshes.
      final seasons = _mergeSeasons(
        await client.getSeasons(widget.series.id, includeMissing: true),
      );
      final selectedKey = selected?.key ?? _season?.key;
      final choice =
          seasons.where((season) => season.key == selectedKey).firstOrNull ??
          seasons.where((season) => season.item != null).firstOrNull ??
          seasons.firstOrNull;
      if (!sessionCurrent(generation) ||
          !identical(ref.read(jellyfinClientProvider), client)) {
        return;
      }
      final episodes = choice != null && choice.item == null
          ? <JellyfinItem>[]
          : await client.getEpisodes(
              widget.series.id,
              seasonId: choice?.item?.id,
              includeMissing: true,
            );
      if (!sessionCurrent(generation) ||
          !identical(ref.read(jellyfinClientProvider), client)) {
        return;
      }
      setState(() {
        _seasons = seasons;
        _season = choice;
        _episodes = episodes;
      });
    } catch (_) {
      if (sessionCurrent(generation)) setState(() => _readFailed = true);
    } finally {
      if (sessionCurrent(generation)) setState(() => _loading = false);
    }
  }

  Future<void> _play(JellyfinItem episode) async {
    final generation = sessionGeneration;
    if (_playing || !sessionCurrent(generation) || !episode.isPlayable) return;
    setState(() {
      _playing = true;
      _playError = null;
    });
    try {
      final client = ref.read(jellyfinClientProvider);
      if (client == null) throw StateError('Media connection unavailable');
      // Recheck this account's current library metadata before player negotiation.
      final current = await client.getItem(episode.id);
      if (current.id != episode.id) {
        throw const FormatException('Invalid media identity');
      }
      if (!mounted ||
          !sessionCurrent(generation) ||
          !identical(ref.read(jellyfinClientProvider), client)) {
        return;
      }
      if (!current.isPlayable) {
        setState(() => _playError = _eligibilityLabel(current));
        return;
      }
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => JellyfinPlayerScreen(item: current),
        ),
      );
      if (!sessionCurrent(generation)) return;
      ref.invalidate(jellyfinResumeItemsProvider);
      ref.invalidate(mediaHubRowsProvider);
      await _load();
    } catch (_) {
      if (sessionCurrent(generation)) {
        setState(
          () => _playError = AppLocalizations.of(context).mediaErrorUnreachable,
        );
      }
    } finally {
      if (sessionCurrent(generation)) setState(() => _playing = false);
    }
  }

  String _eligibilityLabel(JellyfinItem item) {
    final l10n = AppLocalizations.of(context);
    if (item.premiereDate?.isAfter(DateTime.now()) == true &&
        !item.isPlayable) {
      return l10n.mediaEpisodeUnaired;
    }
    if (item.isMissing == true || item.isVirtual) {
      return l10n.mediaEpisodeMissing;
    }
    if (item.playbackEligibility == JellyfinPlaybackEligibility.unknown) {
      return l10n.mediaStatusUnknown;
    }
    return l10n.mediaEpisodeUnavailable;
  }

  String _seasonName(_Season season) =>
      season.item?.name ??
      season.catalogue?.name ??
      (season.number == null
          ? AppLocalizations.of(context).mediaEpisodesTitle
          : AppLocalizations.of(context).mediaSeasonLabel(season.number!));

  @override
  Widget build(BuildContext context) {
    watchMediaAccounts();
    return MediaTheme(builder: _build);
  }

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final client = ref.watch(jellyfinClientProvider);
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
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          widget.series.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            CupertinoSliverRefreshControl(onRefresh: () => _load()),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.mediaEpisodesTitle, style: AppText.title2),
                    const SizedBox(height: 8),
                    Text(l10n.mediaKnownCoverage, style: AppText.footnote),
                    if (_playError != null)
                      Text(
                        _playError!,
                        key: const ValueKey('media-episode-play-error'),
                      ),
                    if (_readFailed) ...[
                      Text(l10n.mediaErrorUnreachable),
                      if (_episodes.isNotEmpty)
                        Text(l10n.mediaProgressStale, style: AppText.footnote),
                    ],
                    CupertinoButton(
                      onPressed: _loading
                          ? null
                          : guardedMediaAction(() => _load()),
                      child: Text(l10n.commonRefresh),
                    ),
                  ],
                ),
              ),
            ),
            if (_seasons.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height:
                      64 *
                      MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _seasons.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final season = _seasons[index];
                      return SizedBox(
                        width: 200,
                        child: CupertinoButton(
                          key: ValueKey('media-season-${season.key}'),
                          color: season.key == _season?.key
                              ? CupertinoColors.tertiarySystemFill.resolveFrom(
                                  context,
                                )
                              : null,
                          onPressed: _loading
                              ? null
                              : guardedMediaAction(
                                  () => _load(selected: season),
                                ),
                          child: Text(
                            _seasonName(season),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (_season != null && !_loading)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_seasonName(_season!), style: AppText.title3),
                      Text(
                        l10n.mediaPlayableCount(
                          _episodes.where((item) => item.isPlayable).length,
                        ),
                      ),
                      if (_episodes.any(
                        (item) => item.isMissing == true || item.isVirtual,
                      ))
                        Text(
                          l10n.mediaMissingCount(
                            _episodes
                                .where(
                                  (item) =>
                                      item.isMissing == true || item.isVirtual,
                                )
                                .length,
                          ),
                        ),
                      if (_season!.catalogue?.episodeCount != null)
                        Text(
                          l10n.mediaExpectedCount(
                            _season!.catalogue!.episodeCount!,
                          ),
                        ),
                      if (_season!.item == null)
                        Text(l10n.mediaSeasonNotListed),
                      for (final coverage in widget.seasonCoverage.where(
                        (coverage) => coverage.seasonNumber == _season!.number,
                      )) ...[
                        if (coverage.downloadedEpisodeCount != null)
                          Text(
                            l10n.mediaDownloadedCount(
                              coverage.downloadedEpisodeCount!,
                              coverage.source.name,
                            ),
                          ),
                      ],
                      Text(l10n.mediaCoverageUnknown, style: AppText.footnote),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: guardedMediaAction(
                          () => context.push('/system/sonarr'),
                        ),
                        child: Text(l10n.mediaOpenService('Sonarr')),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CupertinoActivityIndicator()),
              )
            else if (_episodes.isEmpty && !_readFailed)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(l10n.jellyfinLibraryEmpty),
                ),
              )
            else
              SliverList.builder(
                itemCount: _episodes.length,
                itemBuilder: (context, index) {
                  final episode = _episodes[index];
                  final enabled =
                      episode.isPlayable && !_playing && !_readFailed;
                  final artwork = client?.imageUrl(
                    episode.id,
                    tag: episode.imageTags?['Primary'],
                  );
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: CupertinoColors.secondarySystemGroupedBackground
                            .resolveFrom(context),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          CupertinoButton(
                            key: ValueKey('media-episode-${episode.id}'),
                            padding: const EdgeInsets.all(12),
                            onPressed: enabled
                                ? guardedMediaAction(() => _play(episode))
                                : null,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final wide = constraints.maxWidth >= 600;
                                final content = Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      episode.name,
                                      style: AppText.headline.copyWith(
                                        color: CupertinoColors.label
                                            .resolveFrom(context),
                                      ),
                                    ),
                                    if (episode.parentIndexNumber != null &&
                                        episode.indexNumber != null)
                                      Text(
                                        l10n.mediaEpisodeLabel(
                                          episode.parentIndexNumber!,
                                          episode.indexNumber!,
                                        ),
                                        style: AppText.footnote,
                                      ),
                                    if (!episode.isPlayable)
                                      Text(
                                        _eligibilityLabel(episode),
                                        style: AppText.subhead,
                                      ),
                                    if (episode.userData?.played == true)
                                      Text(
                                        l10n.commonDone,
                                        style: AppText.footnote,
                                      ),
                                    if (episode.overview?.isNotEmpty == true)
                                      Text(
                                        episode.overview!,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppText.subhead,
                                      ),
                                    if (episode.playedFraction.isFinite &&
                                        episode.playedFraction > 0)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: FractionallySizedBox(
                                          widthFactor: episode.playedFraction
                                              .clamp(0, 1),
                                          child: const SizedBox(
                                            height: 3,
                                            child: ColoredBox(
                                              color: CupertinoColors.systemBlue,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                                if (!wide || artwork == null) return content;
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 180,
                                      child: AspectRatio(
                                        aspectRatio: 16 / 9,
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          child: CachedNetworkImage(
                                            imageUrl: artwork,
                                            fit: BoxFit.cover,
                                            errorWidget: (_, _, _) =>
                                                const SizedBox.shrink(),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(child: content),
                                  ],
                                );
                              },
                            ),
                          ),
                          if (enabled)
                            RemotePlaybackButton(
                              key: ValueKey('remote-episode-${episode.id}'),
                              itemId: episode.id,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}
