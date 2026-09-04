import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/theme/app_colors.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../hub/presentation/widgets/media_theme.dart';
import '../../hub/providers/media_catalog_providers.dart';
import '../data/models/jellyfin_item.dart';
import '../providers/jellyfin_providers.dart';
import 'player/jellyfin_player_screen.dart';

/// Series are containers, not video files. Let the viewer choose an actual
/// available episode before asking Jellyfin for a playback source.
class JellyfinSeriesScreen extends ConsumerStatefulWidget {
  const JellyfinSeriesScreen({super.key, required this.series});

  final JellyfinItem series;

  @override
  ConsumerState<JellyfinSeriesScreen> createState() =>
      _JellyfinSeriesScreenState();
}

class _JellyfinSeriesScreenState extends ConsumerState<JellyfinSeriesScreen> {
  List<JellyfinItem> _seasons = [];
  List<JellyfinItem> _episodes = [];
  JellyfinItem? _season;
  bool _loading = true;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({JellyfinItem? season}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ref.read(jellyfinClientProvider);
      if (client == null) throw StateError('Jellyfin disconnected');
      final seasons = _seasons.isEmpty
          ? await client.getSeasons(widget.series.id)
          : _seasons;
      final selected =
          season ?? _season ?? (seasons.isEmpty ? null : seasons.first);
      final episodes = await client.getEpisodes(
        widget.series.id,
        seasonId: selected?.id,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _seasons = seasons;
        _season = selected;
        _episodes = episodes.where((episode) => episode.isPlayable).toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => MediaTheme(builder: _build);

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final client = ref.watch(jellyfinClientProvider);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.series.name)),
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            CupertinoSliverRefreshControl(onRefresh: () => _load()),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.mediaEpisodesTitle,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                    if (_seasons.isNotEmpty)
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        onPressed: _chooseSeason,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_season?.name ?? l10n.mediaFilterAll),
                            const SizedBox(width: 6),
                            const Icon(CupertinoIcons.chevron_down, size: 14),
                          ],
                        ),
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
            else if (_error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(l10n.mediaErrorUnreachable),
                    CupertinoButton(
                      onPressed: () => _load(),
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
              )
            else if (_episodes.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text(l10n.jellyfinLibraryEmpty)),
              )
            else
              SliverList.builder(
                itemCount: _episodes.length,
                itemBuilder: (context, index) {
                  final episode = _episodes[index];
                  final artwork = client?.imageUrl(
                    episode.id,
                    tag: episode.imageTags?['Primary'],
                  );
                  final runtime = episode.runtime;
                  final label = l10n.mediaEpisodeLabel(
                    episode.parentIndexNumber ?? 1,
                    episode.indexNumber ?? index + 1,
                  );
                  return CupertinoButton(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    onPressed: () => _play(episode),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth > 500;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: wide ? 210 : 116,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ColoredBox(
                                        color: AppColors.surface.resolveFrom(
                                          context,
                                        ),
                                      ),
                                      if (artwork != null)
                                        CachedNetworkImage(
                                          imageUrl: artwork,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, _, _) =>
                                              const SizedBox.shrink(),
                                        ),
                                      const Center(
                                        child: Icon(
                                          CupertinoIcons.play_circle_fill,
                                          size: 30,
                                          color: CupertinoColors.white,
                                        ),
                                      ),
                                      if (episode.playedFraction > 0)
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          child: FractionallySizedBox(
                                            alignment: Alignment.centerLeft,
                                            widthFactor: episode.playedFraction
                                                .clamp(0, 1),
                                            child: const SizedBox(
                                              height: 3,
                                              child: ColoredBox(
                                                color:
                                                    CupertinoColors.systemRed,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    episode.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: CupertinoColors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    [
                                      label,
                                      if (runtime != null)
                                        '${runtime.inMinutes} min',
                                      if (episode.userData?.played == true) '✓',
                                    ].join(' · '),
                                    style: const TextStyle(
                                      color: Color(0xFFA2ABBA),
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (wide &&
                                      (episode.overview?.isNotEmpty ??
                                          false)) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      episode.overview!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFA2ABBA),
                                        fontSize: 13,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        );
                      },
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

  Future<void> _chooseSeason() async {
    final chosen = await showCupertinoModalPopup<JellyfinItem>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(AppLocalizations.of(context).mediaEpisodesTitle),
        actions: [
          for (final season in _seasons)
            CupertinoActionSheetAction(
              isDefaultAction: season.id == _season?.id,
              onPressed: () => Navigator.pop(context, season),
              child: Text(season.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (chosen != null && mounted) await _load(season: chosen);
  }

  Future<void> _play(JellyfinItem episode) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => JellyfinPlayerScreen(item: episode)),
    );
    if (!mounted) return;
    ref.invalidate(jellyfinResumeItemsProvider);
    ref.invalidate(mediaHubRowsProvider);
    await _load();
  }
}
