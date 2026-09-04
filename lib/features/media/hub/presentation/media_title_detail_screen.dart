import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../arr/presentation/widgets/arr_add_screen.dart';
import '../../arr/providers/radarr_providers.dart';
import '../../arr/providers/sonarr_providers.dart';
import '../../bazarr/providers/bazarr_providers.dart';
import '../../data/media_api_exception.dart';
import '../../jellyfin/presentation/player/jellyfin_player_screen.dart';
import '../../jellyfin/presentation/jellyfin_series_screen.dart';
import '../../jellyfin/presentation/jellyfin_library_screen.dart';
import 'widgets/media_theme.dart';
import '../../jellyfin/providers/jellyfin_providers.dart';
import '../../jellyseerr/providers/jellyseerr_providers.dart';
import '../domain/media_identity.dart';
import '../domain/media_title.dart';
import '../providers/media_catalog_providers.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';

/// One page per title, pulling together every service that knows about
/// it: play it from Jellyfin, request it through Jellyseerr, add it to
/// Sonarr/Radarr, watch its download progress, and see whether Bazarr is
/// still missing subtitles — instead of checking four apps.
class MediaTitleDetailScreen extends ConsumerStatefulWidget {
  const MediaTitleDetailScreen({super.key, required this.title});

  final MediaTitle title;

  @override
  ConsumerState<MediaTitleDetailScreen> createState() =>
      _MediaTitleDetailScreenState();
}

class _MediaTitleDetailScreenState
    extends ConsumerState<MediaTitleDetailScreen> {
  bool _busy = false;
  String? _message;

  bool _requested = false;

  MediaTitle get _title {
    final title =
        ref.read(mediaLibraryIndexProvider).value?.enrich(widget.title) ??
        widget.title;
    return _requested && !title.isPlayable && title.downloadProgress == null
        ? title.copyWith(availability: MediaAvailability.requested)
        : title;
  }

  @override
  Widget build(BuildContext context) => MediaTheme(builder: _build);

  Widget _build(BuildContext context) {
    ref.watch(mediaLibraryIndexProvider);
    final l10n = AppLocalizations.of(context);
    final artwork = _title.backdropUrl ?? _title.posterUrl;

    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(_title.title, overflow: TextOverflow.ellipsis),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.pageGutter,
                Gap.lg,
                Insets.pageGutter,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title.title, style: AppText.title1),
                  const SizedBox(height: 4),
                  Text(
                    _subtitleLine(l10n),
                    style: TextStyle(
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _primaryAction(l10n),
                  if (_message != null) ...[
                    const SizedBox(height: Gap.md),
                    Text(
                      _message!,
                      style: TextStyle(
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ],
                  if (_title.overview != null) ...[
                    const SizedBox(height: Gap.xl),
                    Text(
                      _title.overview!,
                      style: AppText.body.copyWith(height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _statusSection(l10n),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  String _subtitleLine(AppLocalizations l10n) {
    final parts = <String>[
      _title.isTv ? l10n.mediaKindTv : l10n.mediaKindMovie,
      if (_title.year != null) '${_title.year}',
      if (_title.rating != null) '★ ${_title.rating!.toStringAsFixed(1)}',
    ];
    return parts.join(' · ');
  }

  Widget _primaryAction(AppLocalizations l10n) {
    if (_busy) {
      return const CupertinoButton.filled(
        onPressed: null,
        child: CupertinoActivityIndicator(color: CupertinoColors.white),
      );
    }

    // The one button changes meaning with what's actually possible right
    // now, so there's never a dead action on screen.
    if (_title.isPlayable && ref.watch(jellyfinClientProvider) != null) {
      final resuming = (_title.playedFraction ?? 0) > 0;
      return CupertinoButton.filled(
        onPressed: _play,
        child: Text(
          resuming
              ? l10n.mediaActionResume
              : _title.isTv
              ? l10n.mediaEpisodesTitle
              : l10n.mediaActionPlay,
        ),
      );
    }

    if (_title.availability == MediaAvailability.downloading) {
      final percent = ((_title.downloadProgress ?? 0) * 100).round();
      return CupertinoButton.filled(
        onPressed: null,
        child: Text(l10n.mediaStatusDownloadingPercent(percent)),
      );
    }

    if (_title.availability == MediaAvailability.requested) {
      return CupertinoButton.filled(
        onPressed: null,
        child: Text(l10n.mediaStatusRequested),
      );
    }

    if (_title.availability == MediaAvailability.inLibrary ||
        _title.availability == MediaAvailability.monitored) {
      return CupertinoButton.filled(
        onPressed: null,
        child: Text(_statusLabel(l10n)),
      );
    }

    final canRequest =
        ref.watch(jellyseerrClientProvider) != null &&
        _title.identity.tmdbId != null;
    if (canRequest) {
      return CupertinoButton.filled(
        onPressed: _request,
        child: Text(
          _title.isTv ? l10n.mediaRequestAllSeasons : l10n.mediaActionRequest,
        ),
      );
    }

    // No Jellyseerr — fall back to adding straight through the *arr app,
    // reusing the existing search/profile/root-folder flow.
    final arr = _title.isTv
        ? ref.watch(sonarrClientProvider)
        : ref.watch(radarrClientProvider);
    if (arr != null) {
      return CupertinoButton.filled(
        onPressed: _addViaArr,
        child: Text(l10n.mediaActionAdd),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _statusSection(AppLocalizations l10n) {
    // Bazarr keys its records on the *arr's own row id, which the library
    // index resolved for us — so subtitles only show up once we know it.
    final missingSubtitles = _missingSubtitleCount() ?? 0;

    return CupertinoListSection.insetGrouped(
      children: [
        CupertinoListTile(
          leading: IconBadge(icon: _statusIcon(), color: _statusColor(context)),
          title: Text(_statusLabel(l10n)),
        ),
        if (_title.monitored == true)
          CupertinoListTile(
            leading: const IconBadge(
              icon: CupertinoIcons.eye_fill,
              color: CupertinoColors.systemPurple,
            ),
            title: Text(l10n.mediaStatusMonitoredLabel),
          ),
        if (missingSubtitles > 0)
          CupertinoListTile(
            leading: const IconBadge(
              icon: CupertinoIcons.captions_bubble,
              color: CupertinoColors.systemTeal,
            ),
            title: Text(l10n.mediaSubtitlesMissing(missingSubtitles)),
          ),
      ],
    );
  }

  int? _missingSubtitleCount() {
    final arrId = _title.arrItemId;
    if (arrId == null) return null;

    final wanted = _title.isTv
        ? ref.watch(bazarrMissingEpisodesProvider).value
        : ref.watch(bazarrMissingMoviesProvider).value;
    if (wanted == null) return null;

    return wanted
        .where(
          (item) =>
              _title.isTv ? item.seriesId == arrId : item.radarrId == arrId,
        )
        .fold<int>(0, (sum, item) => sum + item.missingLanguages.length);
  }

  IconData _statusIcon() => switch (_title.availability) {
    MediaAvailability.inLibrary => CupertinoIcons.checkmark_circle_fill,
    MediaAvailability.downloading => CupertinoIcons.arrow_down_circle_fill,
    MediaAvailability.requested => CupertinoIcons.clock_fill,
    MediaAvailability.monitored => CupertinoIcons.eye_fill,
    MediaAvailability.notAvailable => CupertinoIcons.cloud,
  };

  Color _statusColor(BuildContext context) => CupertinoDynamicColor.resolve(
    _statusColorFor(_title.availability),
    context,
  );

  Color _statusColorFor(MediaAvailability availability) =>
      switch (availability) {
        MediaAvailability.inLibrary => CupertinoColors.systemGreen,
        MediaAvailability.downloading => CupertinoColors.systemBlue,
        MediaAvailability.requested => CupertinoColors.systemOrange,
        MediaAvailability.monitored => CupertinoColors.systemPurple,
        MediaAvailability.notAvailable => CupertinoColors.systemGrey,
      };

  String _statusLabel(AppLocalizations l10n) => switch (_title.availability) {
    MediaAvailability.inLibrary => l10n.mediaStatusInLibrary,
    MediaAvailability.downloading => l10n.mediaStatusDownloading,
    MediaAvailability.requested => l10n.mediaStatusRequested,
    MediaAvailability.monitored => l10n.mediaStatusMonitored,
    MediaAvailability.notAvailable => l10n.mediaStatusNotAvailable,
  };

  Future<void> _play() async {
    final client = ref.read(jellyfinClientProvider);
    final itemId = _title.jellyfinItemId;
    if (client == null || itemId == null) return;

    setState(() => _busy = true);
    try {
      // The hub's title carries only what a poster needs; the player
      // wants the real Jellyfin item, so fetch it on the way in.
      final item = await client.getItem(itemId);
      if (!mounted) return;
      await Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => item.isPlayable
              ? JellyfinPlayerScreen(item: item)
              : item.type == 'Series'
              ? JellyfinSeriesScreen(series: item)
              : JellyfinLibraryScreen(parentId: item.id, title: item.name),
        ),
      );
      ref.invalidate(jellyfinResumeItemsProvider);
      ref.invalidate(mediaLibraryIndexProvider);
      ref.invalidate(mediaHubRowsProvider);
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is MediaApiException
              ? e.message
              : AppLocalizations.of(context).mediaErrorUnreachable,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _request() async {
    final client = ref.read(jellyseerrClientProvider);
    final tmdbId = _title.identity.tmdbId;
    if (client == null || tmdbId == null) return;

    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await client.requestMedia(
        mediaType: _title.isTv ? 'tv' : 'movie',
        mediaId: tmdbId,
      );
      ref.invalidate(mediaLibraryIndexProvider);
      ref.invalidate(mediaHubRowsProvider);
      if (mounted) {
        ref.invalidate(mediaSearchProvider);
        setState(() {
          _requested = true;
          _message = l10n.mediaRequestSent;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is MediaApiException
              ? e.message
              : l10n.mediaErrorUnreachable,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addViaArr() async {
    final isTv = _title.isTv;
    final client = isTv
        ? ref.read(sonarrClientProvider)
        : ref.read(radarrClientProvider);
    if (client == null) return;

    final l10n = AppLocalizations.of(context);
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ArrAddScreen(
          title: l10n.mediaActionAdd,
          searchHint: _title.title,
          initialQuery: isTv && _title.identity.tvdbId != null
              ? 'tvdb:${_title.identity.tvdbId}'
              : !isTv && _title.identity.tmdbId != null
              ? 'tmdb:${_title.identity.tmdbId}'
              : _title.title,
          onLookup: client.lookup,
          loadQualityProfiles: client.getQualityProfiles,
          loadRootFolders: client.getRootFolders,
          onAdd:
              (result, qualityProfileId, rootFolderPath, metadataProfileId) =>
                  client.add(
                    result: result,
                    qualityProfileId: qualityProfileId,
                    rootFolderPath: rootFolderPath,
                    metadataProfileId: metadataProfileId,
                  ),
        ),
      ),
    );

    ref.invalidate(mediaLibraryIndexProvider);
    ref.invalidate(mediaHubRowsProvider);
  }
}

/// Convenience for callers that only have ids — used by deep links from
/// rows that don't carry a full title object.
MediaTitle bareMediaTitle(MediaIdentity identity, String title) => MediaTitle(
  identity: identity,
  title: title,
  availability: MediaAvailability.notAvailable,
);
