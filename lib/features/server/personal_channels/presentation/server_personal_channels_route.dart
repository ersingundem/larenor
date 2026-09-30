import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/data/server_media_catalog_controller.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';
import '../../media_playback/data/server_media_playback_api.dart';
import '../../media_playback/domain/server_media_playback_models.dart';
import '../data/server_personal_channel_controller.dart';
import '../domain/server_personal_channel_models.dart';
import 'server_personal_channels_screen.dart';

final class ServerPersonalChannelsRoute extends ConsumerStatefulWidget {
  const ServerPersonalChannelsRoute({super.key});

  @override
  ConsumerState<ServerPersonalChannelsRoute> createState() =>
      _ServerPersonalChannelsRouteState();
}

final class _ServerPersonalChannelsRouteState
    extends ConsumerState<ServerPersonalChannelsRoute> {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch;
  ServerPersonalChannelController? _controller;

  bool _bindingCurrent() {
    final home = _home;
    return mounted &&
        home != null &&
        identical(ref.read(homeSessionControllerProvider), home) &&
        identical(home.runtimeIdentity, _identity) &&
        home.account.generation == _generation &&
        home.interaction.epoch == _homeEpoch;
  }

  bool _current() {
    if (!_bindingCurrent()) return false;
    final home = _home!;
    final session = home.account.session;
    return (_interaction?.active ?? true) &&
        home.source == HomeSource.verifiedCore &&
        !home.busy &&
        home.failure == null &&
        home.interaction.active &&
        session?.context != null &&
        session?.sessionFamilyId != null &&
        session!.user.mustChangePassword == false &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
  }

  void _changed() {
    if (!mounted) return;
    if (!_current()) {
      _controller?.dispose();
      _controller = null;
    } else {
      _controller ??= ServerPersonalChannelController(_home!.account);
    }
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    final interaction = AppInteractionScope.maybeOf(context);
    if (_home == null && home != null) {
      _home = home;
      _identity = home.runtimeIdentity;
      _generation = home.account.generation;
      _homeEpoch = home.interaction.epoch;
      home.addListener(_changed);
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      interaction?.addListener(_changed);
    }
    if (_controller == null && _current()) {
      _controller = ServerPersonalChannelController(_home!.account);
    }
  }

  @override
  void dispose() {
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }

  Future<List<ServerPersonalChannelSource>?> _pickSources(
    BuildContext context, {
    required int maximum,
  }) {
    return showCupertinoModalPopup<List<ServerPersonalChannelSource>>(
      context: context,
      builder: (_) => _PersonalChannelSourcePicker(
        account: _home!.account,
        maximum: maximum.clamp(1, 50),
        current: _current,
      ),
    );
  }

  Future<void> _play(ServerPersonalPlaybackSource source) async {
    if (!_current()) return;
    final account = _home!.account;
    try {
      final intent = await account.withSession(
        (api, session) =>
            ServerMediaPlaybackApi(api, session.accessToken).prepareAuthority(
              installationId: source.installationId,
              installationRevision: source.installationRevision,
              snapshotRevision: source.snapshotRevision,
              jellyfinServiceRevision: source.jellyfinServiceRevision,
              itemId: source.itemId,
              mediaKey: source.mediaKey,
            ),
      );
      if (!mounted || !_current()) return;
      final available = intent.targets
          .where((target) => target.available)
          .toList(growable: false);
      if (available.isEmpty) {
        await _notice(_strings.playbackUnavailable);
        return;
      }
      final target = await showCupertinoModalPopup<ServerMediaPlaybackTarget>(
        context: context,
        builder: (sheetContext) => CupertinoActionSheet(
          title: Text(_strings.choosePlayer),
          actions: [
            for (final target in available)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(sheetContext, target),
                child: Text(target.name),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheetContext),
            child: Text(_strings.cancel),
          ),
        ),
      );
      if (target == null || !mounted || !_current()) return;
      final controller = _controller;
      if (controller == null) return;
      await controller.startContinuous(
        source: source,
        targetId: target.id,
        current: _current,
      );
      if (!_current()) return;
      if (controller.failure != null) {
        await _notice(_error(controller.failure!));
        return;
      }
      final execution = controller.execution;
      await _notice(
        execution?.state == ServerPersonalExecutionState.active &&
                execution?.code ==
                    ServerPersonalExecutionCode.authenticatedReadback
            ? _strings.playbackStarted
            : _strings.playbackNeedsAttention,
      );
    } on LarenorServerException catch (error) {
      if (_current()) await _notice(_error(error.code));
    } catch (_) {
      if (_current()) await _notice(_strings.unavailable);
    }
  }

  Future<void> _notice(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(_strings.ok),
        ),
      ],
    ),
  );

  _PersonalChannelRouteStrings get _strings =>
      _PersonalChannelRouteStrings.of(context);

  String _error(String code) => switch (code) {
    'personal_channel_authority_changed' => _strings.authorityChanged,
    'personal_channel_changed' => _strings.changed,
    'personal_channel_cancelled' => _strings.cancelled,
    'personal_channel_limit_reached' ||
    'personal_channel_guide_limit_reached' => _strings.limit,
    'personal_channel_source_unavailable' => _strings.sourceUnavailable,
    'personal_channel_programme_not_live' ||
    'personal_channel_programme_not_started' => _strings.notLive,
    _ => _strings.unavailable,
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    final controller = _controller;
    if (controller != null && _current()) {
      final s = _strings;
      return ServerPersonalChannelsScreen(
        controller: controller,
        strings: ServerPersonalChannelStrings(
          title: s.title,
          empty: s.empty,
          create: s.create,
          channelName: s.channelName,
          loopSchedule: s.loopSchedule,
          guide: s.guide,
          live: s.live,
          restart: s.restart,
          gapDeleted: s.gapDeleted,
          gapUnreachable: s.gapUnreachable,
          reschedule: s.reschedule,
          cancelChannel: s.cancelChannel,
          cancel: s.cancel,
          keep: s.keep,
          retry: s.retry,
          ok: s.ok,
          noAuthorizedSources: s.noAuthorizedSources,
        ),
        pickSources: _pickSources,
        onPlayback: _play,
        errorLabel: _error,
      );
    }
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(_strings.title)),
      child: SafeArea(child: Center(child: Text(_strings.unavailable))),
    );
  }
}

final class _PersonalChannelSourcePicker extends StatefulWidget {
  const _PersonalChannelSourcePicker({
    required this.account,
    required this.maximum,
    required this.current,
  });

  final ServerAccountController account;
  final int maximum;
  final bool Function() current;

  @override
  State<_PersonalChannelSourcePicker> createState() =>
      _PersonalChannelSourcePickerState();
}

final class _PersonalChannelSourcePickerState
    extends State<_PersonalChannelSourcePicker> {
  late final ServerMediaCatalogController _catalog;
  final _query = TextEditingController();
  final _selected = <String>{};

  bool _current() => mounted && widget.current();

  @override
  void initState() {
    super.initState();
    _catalog = ServerMediaCatalogController(widget.account);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current()) {
        _catalog.browseCurrent(limit: 50, current: _current);
      }
    });
  }

  @override
  void dispose() {
    _catalog.dispose();
    _query.dispose();
    super.dispose();
  }

  void _search(String value) {
    final query = value.trim();
    _selected.clear();
    if (query.isEmpty) {
      _catalog.browseCurrent(limit: 50, current: _current);
    } else {
      _catalog.searchCurrent(query: query, limit: 50, current: _current);
    }
  }

  void _finish() {
    final page = _catalog.page;
    if (page == null || !_current()) return;
    final sources = page.items
        .where((item) => _selected.contains(item.itemId))
        .map(
          (item) => ServerPersonalChannelSource.fromCatalog(
            page,
            item,
            duration: Duration(seconds: item.runtimeSeconds!),
          ),
        )
        .toList(growable: false);
    Navigator.pop(context, sources);
  }

  @override
  Widget build(BuildContext context) {
    final strings = _PersonalChannelRouteStrings.of(context);
    return Container(
      height: MediaQuery.sizeOf(context).height * .82,
      color: CupertinoDynamicColor.resolve(
        CupertinoColors.systemBackground,
        context,
      ),
      child: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: _catalog,
          builder: (context, _) {
            final items =
                (_catalog.page?.items ?? const <ServerMediaCatalogItem>[])
                    .where(
                      (item) =>
                          item.runtimeSeconds != null &&
                          item.runtimeSeconds! >= 60 &&
                          item.runtimeSeconds! <= 86400,
                    )
                    .toList(growable: false);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.chooseSources,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        onPressed: _selected.isEmpty ? null : _finish,
                        child: Text('${strings.add} (${_selected.length})'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: CupertinoSearchTextField(
                    controller: _query,
                    placeholder: strings.search,
                    onSubmitted: _search,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _catalog.busy && items.isEmpty
                      ? const Center(child: CupertinoActivityIndicator())
                      : _catalog.failure != null
                      ? Center(
                          child: CupertinoButton.filled(
                            onPressed: () => _search(_query.text),
                            child: Text(strings.retry),
                          ),
                        )
                      : items.isEmpty
                      ? Center(child: Text(strings.noAuthorizedSources))
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            final selected = _selected.contains(item.itemId);
                            return CupertinoListTile(
                              title: Text(item.title),
                              subtitle: Text(
                                '${(item.runtimeSeconds! / 60).ceil()} min',
                              ),
                              trailing: Icon(
                                selected
                                    ? CupertinoIcons.check_mark_circled_solid
                                    : CupertinoIcons.circle,
                              ),
                              onTap: () {
                                setState(() {
                                  if (selected) {
                                    _selected.remove(item.itemId);
                                  } else if (_selected.length <
                                      widget.maximum) {
                                    _selected.add(item.itemId);
                                  }
                                });
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _PersonalChannelRouteStrings {
  const _PersonalChannelRouteStrings({
    required this.title,
    required this.empty,
    required this.create,
    required this.channelName,
    required this.loopSchedule,
    required this.guide,
    required this.live,
    required this.restart,
    required this.gapDeleted,
    required this.gapUnreachable,
    required this.reschedule,
    required this.cancelChannel,
    required this.cancel,
    required this.keep,
    required this.retry,
    required this.ok,
    required this.noAuthorizedSources,
    required this.chooseSources,
    required this.search,
    required this.add,
    required this.choosePlayer,
    required this.playbackStarted,
    required this.playbackNeedsAttention,
    required this.playbackUnavailable,
    required this.unavailable,
    required this.authorityChanged,
    required this.changed,
    required this.cancelled,
    required this.limit,
    required this.sourceUnavailable,
    required this.notLive,
  });

  static const en = _PersonalChannelRouteStrings(
    title: 'Personal channels',
    empty: 'No personal channel yet.',
    create: 'Create channel',
    channelName: 'Channel name',
    loopSchedule: 'Loop schedule',
    guide: 'Programme guide',
    live: 'Watch live',
    restart: 'Restart',
    gapDeleted: 'Deleted title',
    gapUnreachable: 'Unavailable title',
    reschedule: 'Replace title',
    cancelChannel: 'Cancel channel',
    cancel: 'Cancel',
    keep: 'Keep',
    retry: 'Try again',
    ok: 'OK',
    noAuthorizedSources: 'No authorized playable title was found.',
    chooseSources: 'Choose channel titles',
    search: 'Search library',
    add: 'Add',
    choosePlayer: 'Choose a player',
    playbackStarted: 'Playback started.',
    playbackNeedsAttention:
        'The player needs attention. Check its current state.',
    playbackUnavailable: 'No available managed player was found.',
    unavailable: 'Personal channels are unavailable.',
    authorityChanged: 'The media library changed. Refresh the channel.',
    changed: 'The channel changed. Refresh it.',
    cancelled: 'This channel ended.',
    limit: 'The personal channel limit was reached.',
    sourceUnavailable: 'This title is no longer available.',
    notLive: 'This programme cannot be played at this time.',
  );
  static const tr = _PersonalChannelRouteStrings(
    title: 'Kişisel kanallar',
    empty: 'Henüz kişisel kanal yok.',
    create: 'Kanal oluştur',
    channelName: 'Kanal adı',
    loopSchedule: 'Döngülü yayın',
    guide: 'Program rehberi',
    live: 'Canlı izle',
    restart: 'Baştan başlat',
    gapDeleted: 'Silinmiş içerik',
    gapUnreachable: 'Erişilemeyen içerik',
    reschedule: 'İçeriği değiştir',
    cancelChannel: 'Kanalı iptal et',
    cancel: 'Vazgeç',
    keep: 'Koru',
    retry: 'Tekrar dene',
    ok: 'Tamam',
    noAuthorizedSources: 'Yetkili ve oynatılabilir içerik bulunamadı.',
    chooseSources: 'Kanal içeriklerini seç',
    search: 'Kütüphanede ara',
    add: 'Ekle',
    choosePlayer: 'Oynatıcı seç',
    playbackStarted: 'Oynatma başlatıldı.',
    playbackNeedsAttention:
        'Oynatıcı ilgilenmenizi bekliyor. Güncel durumunu kontrol edin.',
    playbackUnavailable: 'Kullanılabilir yönetilen oynatıcı bulunamadı.',
    unavailable: 'Kişisel kanallar kullanılamıyor.',
    authorityChanged: 'Medya kütüphanesi değişti. Kanalı yenileyin.',
    changed: 'Kanal değişti. Yenileyin.',
    cancelled: 'Bu kanal sona erdi.',
    limit: 'Kişisel kanal sınırına ulaşıldı.',
    sourceUnavailable: 'Bu içerik artık kullanılamıyor.',
    notLive: 'Bu program şu anda oynatılamaz.',
  );

  final String title, empty, create, channelName, loopSchedule, guide;
  final String live, restart, gapDeleted, gapUnreachable, reschedule;
  final String cancelChannel, cancel, keep, retry, ok, noAuthorizedSources;
  final String chooseSources, search, add, choosePlayer, playbackStarted;
  final String playbackNeedsAttention, playbackUnavailable, unavailable;
  final String authorityChanged, changed, cancelled, limit;
  final String sourceUnavailable, notLive;

  static _PersonalChannelRouteStrings of(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'tr' ? tr : en;
}
