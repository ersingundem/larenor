import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../dashboard/presentation/widgets/more_info_sheet.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/presentation/health_labels.dart';
import '../../ha_playback/presentation/ha_playback_screen.dart';
import '../../hub/presentation/media_session_state.dart';
import '../../local_audio/presentation/local_audio_screen.dart';
import '../domain/music_models.dart';
import '../domain/music_playback_models.dart';
import '../providers/music_providers.dart';
import 'music_playback_screen.dart';

String musicTypeLabel(AppLocalizations l10n, MusicMediaType type) =>
    switch (type) {
      MusicMediaType.artist => l10n.musicArtist,
      MusicMediaType.album => l10n.musicAlbum,
      MusicMediaType.track => l10n.musicTrack,
      MusicMediaType.playlist => l10n.musicPlaylist,
      MusicMediaType.radio => l10n.musicRadio,
      MusicMediaType.audiobook => l10n.musicAudiobook,
      MusicMediaType.podcast => l10n.musicPodcast,
    };

String musicFailureLabel(
  AppLocalizations l10n,
  MusicFailure failure,
) => switch (failure) {
  MusicFailure.authentication => healthFailureLabel(
    l10n,
    HealthFailure.authentication,
  ),
  MusicFailure.permission => healthFailureLabel(l10n, HealthFailure.permission),
  MusicFailure.transport => healthFailureLabel(l10n, HealthFailure.transport),
  MusicFailure.timeout => healthFailureLabel(l10n, HealthFailure.timeout),
  MusicFailure.notConfigured => l10n.commonNotConnected,
  MusicFailure.unsupported => l10n.musicServiceMissing,
  MusicFailure.stale || MusicFailure.invalidSelection => l10n.musicStale,
  _ => l10n.healthReadError,
};

enum _MusicTab { outputs, library, search, queue }

String _stateLabel(AppLocalizations l10n, String state) => switch (state) {
  'playing' => l10n.entityStatePlaying,
  'paused' => l10n.entityStatePaused,
  'idle' => l10n.entityStateIdle,
  'standby' => l10n.entityStateStandby,
  'off' => l10n.entityStateOff,
  'on' => l10n.entityStateOn,
  'unavailable' => l10n.entityStateUnavailable,
  'unknown' => l10n.commonUnknown,
  _ => state,
};

class MusicCenterScreen extends ConsumerStatefulWidget {
  const MusicCenterScreen({super.key});
  @override
  ConsumerState<MusicCenterScreen> createState() => _MusicCenterScreenState();
}

class _MusicCenterScreenState extends MediaSessionState<MusicCenterScreen> {
  _MusicTab _tab = _MusicTab.outputs;
  MusicMediaType _type = MusicMediaType.track;
  String? _entryId;
  String? _queueEntityId;
  int _offset = 0;
  String _submitted = '';
  final _search = TextEditingController();
  Route<String>? _selector;
  bool _tickerVisible = true;
  bool _openingPlayback = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_tickerVisible && !visible) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    _tickerVisible = visible;
  }

  @override
  void clearPendingInteraction() {
    _submitted = '';
    _search.clear();
    _queueEntityId = null;
    _openingPlayback = false;
    final route = _selector;
    _selector = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _active =>
      foreground && !sessionExpired && TickerMode.valuesOf(context).enabled;
  bool _canAct(int generation) =>
      sessionCurrent(generation) &&
      _active &&
      ModalRoute.of(context)?.isCurrent == true;

  Future<String?> _selectRoute(WidgetBuilder builder) async {
    final route = CupertinoModalPopupRoute<String>(
      builder: builder,
      barrierLabel: AppLocalizations.of(context).commonCancel,
    );
    _selector = route;
    try {
      return await Navigator.of(context).push(route);
    } finally {
      if (identical(_selector, route)) _selector = null;
    }
  }

  Future<void> _openPlayback(
    MusicCatalogSelection selection,
    int generation,
  ) async {
    if (!_canAct(generation) || _openingPlayback) return;
    if (!identical(
      ref.read(musicAccountGenerationProvider),
      selection.accountGeneration,
    )) {
      return;
    }
    setState(() => _openingPlayback = true);
    try {
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => MusicPlaybackScreen(selection: selection),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingPlayback = false);
    }
  }

  Future<void> _chooseEntry(MusicDiscovery discovery) async {
    final generation = sessionGeneration;
    if (!_canAct(generation)) return;
    final l10n = AppLocalizations.of(context);
    final selected = await _selectRoute(
      (dialogContext) => CupertinoActionSheet(
        title: Text(l10n.musicChooseServer),
        actions: [
          for (final entry in discovery.entries.where(
            (entry) => entry.isLoaded,
          ))
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(dialogContext, entry.id),
              child: Column(
                children: [
                  Text(entry.title),
                  if (!entry.isLoaded)
                    Text(l10n.musicEntryUnavailable, style: AppText.footnote),
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    if (selected == null || !_canAct(generation)) return;
    final latest = ref.read(musicDiscoveryProvider);
    if (latest.isLoading ||
        latest.hasError ||
        !identical(
          latest.value?.accountGeneration,
          discovery.accountGeneration,
        )) {
      return;
    }
    if (!latest.value!.entries.any(
      (entry) => entry.id == selected && entry.isLoaded,
    )) {
      return;
    }
    setState(() {
      _entryId = selected;
      _queueEntityId = null;
      _offset = 0;
      _submitted = '';
    });
  }

  Future<void> _chooseQueue(MusicDiscovery discovery) async {
    final generation = sessionGeneration;
    if (!_canAct(generation)) return;
    final l10n = AppLocalizations.of(context);
    final selected = await _selectRoute(
      (dialogContext) => CupertinoActionSheet(
        title: Text(l10n.musicChooseOutput),
        actions: [
          for (final target in discovery.queueTargets.where(
            (target) =>
                target.configEntryId == _entryId &&
                target.enabled &&
                target.available,
          ))
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(dialogContext, target.entityId),
              child: Text(target.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    if (selected == null || !_canAct(generation)) return;
    final latest = ref.read(musicDiscoveryProvider);
    if (latest.isLoading ||
        latest.hasError ||
        !identical(
          latest.value?.accountGeneration,
          discovery.accountGeneration,
        )) {
      return;
    }
    if (!latest.value!.queueTargets.any(
      (target) =>
          target.entityId == selected &&
          target.configEntryId == _entryId &&
          target.enabled &&
          target.available,
    )) {
      return;
    }
    setState(() => _queueEntityId = selected);
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccount(IntegrationId.ha, connectionConfigProvider);
    final l10n = AppLocalizations.of(context);
    // Selection identity survives ordinary tab switches; this provider is local
    // metadata only and never creates a connection or sends a request.
    ref.watch(musicAccountGenerationProvider);
    final generation = sessionGeneration;
    final reading = _active ? ref.watch(musicDiscoveryProvider) : null;
    final discovery = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final selectedEntry = discovery?.entries
        .where((entry) => entry.id == _entryId && entry.isLoaded)
        .firstOrNull;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.musicTitle)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: CustomScrollView(
              key: const PageStorageKey('music-center'),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final tab in _MusicTab.values)
                              CupertinoButton(
                                color: _tab == tab
                                    ? CupertinoColors.activeBlue
                                    : null,
                                foregroundColor: _tab == tab
                                    ? CupertinoColors.white
                                    : null,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                onPressed: _active
                                    ? () {
                                        if (_canAct(generation)) {
                                          setState(() => _tab = tab);
                                        }
                                      }
                                    : null,
                                child: Text(switch (tab) {
                                  _MusicTab.outputs => l10n.musicOutputs,
                                  _MusicTab.library => l10n.musicLibrary,
                                  _MusicTab.search => l10n.musicSearch,
                                  _MusicTab.queue => l10n.musicQueue,
                                }),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (sessionExpired)
                          Text(l10n.mediaRemoteAccountChanged)
                        else if (reading?.isLoading == true)
                          const CupertinoActivityIndicator()
                        else if (reading?.hasError == true)
                          Text(l10n.healthReadError)
                        else if (discovery?.configured == false)
                          Text(l10n.commonNotConnected),
                        if (discovery?.issues.isNotEmpty == true)
                          Text(l10n.musicPartial),
                        if (discovery != null)
                          Text(
                            l10n.energyLastChecked(
                              DateFormat.yMd(l10n.localeName)
                                  .add_Hms()
                                  .format(discovery.readAt.toLocal()),
                            ),
                            style: AppText.footnote,
                          ),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: !_active || reading?.isLoading == true
                              ? null
                              : () {
                                  if (!_canAct(generation)) return;
                                  if (_tab == _MusicTab.queue &&
                                      discovery != null &&
                                      selectedEntry != null) {
                                    final query = _queueQuery(discovery);
                                    if (query != null) {
                                      ref
                                          .read(
                                            musicQueueControllerProvider(query),
                                          )
                                          ?.refresh();
                                    }
                                  }
                                  ref.invalidate(musicDiscoveryProvider);
                                  if (_tab == _MusicTab.library &&
                                      discovery != null &&
                                      selectedEntry != null) {
                                    ref.invalidate(
                                      musicLibraryProvider(
                                        _libraryQuery(discovery),
                                      ),
                                    );
                                  }
                                  if (_tab == _MusicTab.search &&
                                      discovery != null &&
                                      selectedEntry != null &&
                                      _submitted.isNotEmpty) {
                                    ref.invalidate(
                                      musicSearchProvider(
                                        _searchQuery(discovery),
                                      ),
                                    );
                                  }
                                },
                          child: Text(l10n.commonRefresh),
                        ),
                        if (_tab != _MusicTab.outputs && discovery != null) ...[
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: discovery.entries.isEmpty
                                ? null
                                : () => _chooseEntry(discovery),
                            child: Text(
                              selectedEntry?.title ?? l10n.musicChooseServer,
                            ),
                          ),
                          if (discovery.assistantNotInstalled)
                            Text(l10n.musicNoAssistant),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_tab == _MusicTab.outputs)
                  ..._outputs(context, discovery, generation),
                if (_tab != _MusicTab.outputs &&
                    discovery?.assistantNotInstalled == true)
                  SliverToBoxAdapter(
                    child: MusicPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.musicAssistantHint, style: AppText.body),
                          const SizedBox(height: 12),
                          Text(l10n.musicProviderHint, style: AppText.footnote),
                        ],
                      ),
                    ),
                  ),
                if (discovery != null && selectedEntry != null && _active)
                  ...switch (_tab) {
                    _MusicTab.library => _library(
                      context,
                      discovery,
                      generation,
                    ),
                    _MusicTab.search => _searchView(
                      context,
                      discovery,
                      generation,
                    ),
                    _MusicTab.queue => _queue(context, discovery, generation),
                    _MusicTab.outputs => <Widget>[],
                  },
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _outputs(
    BuildContext context,
    MusicDiscovery? discovery,
    int generation,
  ) {
    final l10n = AppLocalizations.of(context);
    final targets = discovery?.inventory?.targets;
    return [
      SliverToBoxAdapter(
        child: MusicPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.musicOutputs, style: AppText.title2),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _active
                        ? () {
                            if (_canAct(generation)) {
                              Navigator.of(context).push(
                                CupertinoPageRoute<void>(
                                  builder: (_) => const LocalAudioScreen(),
                                ),
                              );
                            }
                          }
                        : null,
                    child: Text(l10n.localAudioTitle),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _active
                        ? () {
                            if (_canAct(generation)) {
                              Navigator.of(context).push(
                                CupertinoPageRoute<void>(
                                  builder: (_) => const HaPlaybackScreen(),
                                ),
                              );
                            }
                          }
                        : null,
                    child: Text(l10n.haMediaTitle),
                  ),
                ],
              ),
              if (targets?.isEmpty == true) Text(l10n.haMediaNoTargets),
            ],
          ),
        ),
      ),
      if (targets != null)
        SliverList.builder(
          itemCount: targets.length,
          itemBuilder: (context, index) {
            final target = targets[index];
            return MusicPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        target.isDisplay
                            ? CupertinoIcons.tv
                            : CupertinoIcons.speaker_2,
                        size: 28,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(target.name, style: AppText.headline),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    haMediaReceiverLabel(l10n, target.receiverKind),
                    style: AppText.footnote,
                  ),
                  if (target.mediaTitle != null)
                    Text(target.mediaTitle!, style: AppText.title3),
                  if (target.mediaArtist != null)
                    Text(target.mediaArtist!, style: AppText.body),
                  if (target.mediaAlbum != null)
                    Text(target.mediaAlbum!, style: AppText.subhead),
                  Text(
                    '${l10n.musicRecordedState}: ${_stateLabel(l10n, target.state)}',
                    style: AppText.footnote,
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: !_active || !target.enabled || !target.available
                        ? null
                        : () {
                            if (_canAct(generation)) {
                              showEntityMoreInfo(context, target.entityId);
                            }
                          },
                    child: Text(l10n.musicDeviceControls),
                  ),
                ],
              ),
            );
          },
        ),
      SliverToBoxAdapter(
        child: MusicPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.musicSourceInfo, style: AppText.title2),
              const SizedBox(height: 12),
              if (discovery?.assistantNotInstalled == true)
                Text(l10n.musicNoAssistant),
              Text(l10n.musicAssistantHint, style: AppText.body),
              const SizedBox(height: 12),
              Text(l10n.musicProviderHint, style: AppText.footnote),
            ],
          ),
        ),
      ),
    ];
  }

  MusicLibraryQuery _libraryQuery(MusicDiscovery discovery) =>
      MusicLibraryQuery(
        accountGeneration: discovery.accountGeneration,
        configEntryId: _entryId!,
        type: _type,
        offset: _offset,
      );
  MusicSearchQuery _searchQuery(MusicDiscovery discovery) => MusicSearchQuery(
    accountGeneration: discovery.accountGeneration,
    configEntryId: _entryId!,
    text: _submitted,
  );

  MusicQueueQuery? _queueQuery(MusicDiscovery discovery) {
    final target = discovery.queueTargets
        .where(
          (target) =>
              target.entityId == _queueEntityId &&
              target.configEntryId == _entryId &&
              target.enabled &&
              target.available,
        )
        .firstOrNull;
    return target == null
        ? null
        : MusicQueueQuery(
            accountGeneration: discovery.accountGeneration,
            configEntryId: target.configEntryId,
            entityId: target.entityId,
          );
  }

  List<Widget> _library(
    BuildContext context,
    MusicDiscovery discovery,
    int generation,
  ) {
    final l10n = AppLocalizations.of(context);
    if (!discovery.services.contains(MusicReadService.getLibrary)) {
      return [_message(l10n.musicServiceMissing)];
    }
    final query = _libraryQuery(discovery);
    final reading = ref.watch(musicLibraryProvider(query));
    final read = reading.isLoading || reading.hasError ? null : reading.value;
    final page = read?.failure == null ? read?.value : null;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final type in MusicMediaType.values)
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: _type == type ? CupertinoColors.activeBlue : null,
                  foregroundColor: _type == type ? CupertinoColors.white : null,
                  onPressed: () {
                    if (_canAct(generation)) {
                      setState(() {
                        _type = type;
                        _offset = 0;
                      });
                    }
                  },
                  child: Text(musicTypeLabel(l10n, type)),
                ),
            ],
          ),
        ),
      ),
      ..._readState(l10n, reading.isLoading, reading.hasError, read?.failure),
      if (page != null)
        ..._items(
          context,
          page.items,
          selection: (item) => MusicCatalogSelection.library(query, item),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(
            spacing: 16,
            children: [
              if (_offset > 0)
                CupertinoButton(
                  onPressed: reading.isLoading
                      ? null
                      : () {
                          if (_canAct(generation)) {
                            setState(
                              () => _offset = (_offset - 25).clamp(0, 1000000),
                            );
                          }
                        },
                  child: Text(l10n.musicPreviousPage),
                ),
              if (page?.mayHaveMore == true && _offset < 1000000)
                CupertinoButton(
                  onPressed: reading.isLoading
                      ? null
                      : () {
                          if (_canAct(generation)) {
                            setState(() => _offset += 25);
                          }
                        },
                  child: Text(l10n.musicNextPage),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _searchView(
    BuildContext context,
    MusicDiscovery discovery,
    int generation,
  ) {
    final l10n = AppLocalizations.of(context);
    if (!discovery.services.contains(MusicReadService.search)) {
      return [_message(l10n.musicServiceMissing)];
    }
    void submit(String value) {
      if (_canAct(generation)) setState(() => _submitted = value.trim());
    }

    final query = _submitted.isEmpty ? null : _searchQuery(discovery);
    final reading = query == null
        ? null
        : ref.watch(musicSearchProvider(query));
    final read = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              CupertinoTextField(
                key: const ValueKey('music-search-field'),
                controller: _search,
                maxLength: 256,
                placeholder: l10n.musicSearchPlaceholder,
                textInputAction: TextInputAction.search,
                onSubmitted: submit,
                padding: const EdgeInsets.all(14),
              ),
              CupertinoButton(
                onPressed: () => submit(_search.text),
                child: Text(l10n.musicSearch),
              ),
            ],
          ),
        ),
      ),
      if (_submitted.isEmpty)
        _message(l10n.musicSearchPrompt)
      else
        ..._readState(
          l10n,
          reading?.isLoading == true,
          reading?.hasError == true,
          read?.failure,
        ),
      if (read?.value != null && read?.failure == null)
        ..._items(
          context,
          read!.value!.items,
          selection: (item) => MusicCatalogSelection.search(query!, item),
        ),
    ];
  }

  List<Widget> _queue(
    BuildContext context,
    MusicDiscovery discovery,
    int generation,
  ) {
    final l10n = AppLocalizations.of(context);
    if (!discovery.services.contains(MusicReadService.getQueue)) {
      return [_message(l10n.musicServiceMissing)];
    }
    final target = discovery.queueTargets
        .where(
          (target) =>
              target.entityId == _queueEntityId &&
              target.configEntryId == _entryId &&
              target.enabled &&
              target.available,
        )
        .firstOrNull;
    final query = _queueQuery(discovery);
    final reading = query == null ? null : ref.watch(musicQueueProvider(query));
    final read = reading == null || reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final queue = read?.failure == null && read?.isPaused == false
        ? read?.value
        : null;
    return [
      SliverToBoxAdapter(
        child: MusicPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.musicQueueHint, style: AppText.body),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => _chooseQueue(discovery),
                child: Text(target?.name ?? l10n.musicChooseOutput),
              ),
            ],
          ),
        ),
      ),
      ..._readState(
        l10n,
        reading?.isLoading == true,
        reading?.hasError == true,
        read?.failure,
      ),
      if (queue != null)
        SliverToBoxAdapter(
          child: MusicPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(queue.name, style: AppText.title2),
                Text(
                  '${l10n.musicQueueCount}: ${queue.itemCount}',
                  style: AppText.subhead,
                ),
                const SizedBox(height: 16),
                Text(l10n.musicCurrentItem, style: AppText.headline),
                Text(queue.current?.name ?? l10n.commonUnknown),
                if (queue.current?.media?.artists.isNotEmpty == true)
                  Text(queue.current!.media!.artists.join(', ')),
                const SizedBox(height: 16),
                Text(l10n.musicNextItem, style: AppText.headline),
                Text(queue.next?.name ?? l10n.commonUnknown),
              ],
            ),
          ),
        ),
    ];
  }

  List<Widget> _items(
    BuildContext context,
    List<MusicMediaItem> items, {
    required MusicCatalogSelection Function(MusicMediaItem) selection,
  }) {
    final l10n = AppLocalizations.of(context);
    final generation = sessionGeneration;
    if (items.isEmpty) return [_message(l10n.musicEmpty)];
    return [
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return MusicPanel(
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
              onPressed: !_active || _openingPlayback
                  ? null
                  : () => _openPlayback(selection(item), generation),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.music_note_list, size: 28),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: AppText.headline.copyWith(
                            color: CupertinoColors.label.resolveFrom(context),
                          ),
                        ),
                        if (item.artists.isNotEmpty)
                          Text(
                            item.artists.join(', '),
                            style: AppText.subhead.copyWith(
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        if (item.album != null)
                          Text(
                            item.album!,
                            style: AppText.footnote.copyWith(
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        Text(
                          musicTypeLabel(l10n, item.type),
                          style: AppText.footnote.copyWith(
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ];
  }

  List<Widget> _readState(
    AppLocalizations l10n,
    bool loading,
    bool error,
    MusicFailure? failure,
  ) => [
    if (loading)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: CupertinoActivityIndicator(),
        ),
      )
    else if (error)
      _message(l10n.healthReadError)
    else if (failure != null)
      _message(musicFailureLabel(l10n, failure)),
  ];
  Widget _message(String text) => SliverToBoxAdapter(
    child: MusicPanel(child: Text(text, style: AppText.body)),
  );
}

class MusicPanel extends StatelessWidget {
  const MusicPanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
    ),
    child: child,
  );
}
