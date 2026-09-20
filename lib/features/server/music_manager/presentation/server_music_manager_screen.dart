import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_music_manager_controller.dart';
import '../domain/server_music_manager_models.dart';

class ServerMusicManagerScreen extends ConsumerStatefulWidget {
  const ServerMusicManagerScreen({super.key, this.controller});

  @visibleForTesting
  final ServerMusicManagerController? controller;

  @override
  ConsumerState<ServerMusicManagerScreen> createState() =>
      _ServerMusicManagerScreenState();
}

class _ServerMusicManagerScreenState
    extends ConsumerState<ServerMusicManagerScreen>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ServerMusicManagerController _controller;
  late final bool _ownsController;
  late final int _accountEpoch;
  final _search = TextEditingController();
  ValueListenable<TickerModeData>? _ticker;
  int _lifecycle = 0;
  bool _visible = true, _loaded = false, _expired = false;

  bool get _active =>
      mounted &&
      !_expired &&
      _visible &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _controller = widget.controller ?? ServerMusicManagerController(_account);
    _ownsController = widget.controller == null;
    _account.addListener(_accountChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _expire();
  }

  void _expire() {
    if (_expired) return;
    _expired = true;
    _lifecycle++;
    _controller.invalidate();
    _search.clear();
  }

  bool Function() _capture() {
    final lifecycle = _lifecycle;
    return () => _active && lifecycle == _lifecycle;
  }

  void _load() {
    final current = _capture();
    if (current()) unawaited(_controller.load(current: current));
  }

  void _verify() {
    final current = _capture();
    if (current()) unawaited(_controller.verify(current: current));
  }

  void _submitSearch(String value) {
    final current = _capture();
    if (current()) unawaited(_controller.search(value, current: current));
  }

  void _command(ServerMusicOperation operation, {double? positionSeconds}) {
    final current = _capture();
    if (current()) {
      unawaited(
        _controller.command(
          operation,
          positionSeconds: positionSeconds,
          current: current,
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    if (_ownsController) _controller.dispose();
    _search.dispose();
    super.dispose();
  }

  String _providerName(String domain) => switch (domain) {
    'spotify' => 'Spotify',
    'apple_music' => 'Apple Music',
    _ => 'YouTube Music',
  };

  String _receiverKind(AppLocalizations l, String kind) => switch (kind) {
    'homepod' => 'HomePod',
    'airplay' || 'airplay_group' => 'AirPlay',
    'cast' || 'cast_group' => 'Google Cast',
    'group' => l.serverMusicManagerGroup,
    _ => l.serverMusicManagerOther,
  };

  Widget _bounded(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: child,
    ),
  );

  Widget _evidence(
    AppLocalizations l,
    String keyName,
    String title,
    bool value,
  ) => Semantics(
    key: ValueKey('music-manager-$keyName'),
    liveRegion: true,
    label: '$title: ${value ? l.commonYes : l.commonNo}',
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Icon(
              value
                  ? CupertinoIcons.check_mark_circled_solid
                  : CupertinoIcons.circle,
              color: value
                  ? CupertinoColors.activeGreen
                  : CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title)),
          Text(value ? l.commonYes : l.commonNo),
        ],
      ),
    ),
  );

  List<Widget> _status(AppLocalizations l) => [
    SliverToBoxAdapter(
      child: _bounded(
        SettingsSection(
          header: Text(l.serverMusicManagerEvidence),
          footer: Text(l.serverMusicManagerEvidenceHint),
          children: [
            _evidence(
              l,
              'stored',
              l.serverMusicManagerStored,
              _controller.stored,
            ),
            _evidence(
              l,
              'reachable',
              l.serverMusicManagerReachable,
              _controller.reachable,
            ),
            _evidence(
              l,
              'verified',
              l.serverMusicManagerVerified,
              _controller.verified,
            ),
          ],
        ),
      ),
    ),
    SliverToBoxAdapter(
      child: _bounded(
        SettingsSection(
          children: [
            SettingsActionTile(
              buttonKey: const ValueKey('music-manager-load'),
              leading: const Icon(CupertinoIcons.arrow_clockwise),
              title: Text(l.serverMusicManagerRead),
              onTap: _active && !_controller.busy ? _load : null,
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('music-manager-verify'),
              leading: const Icon(CupertinoIcons.check_mark_circled),
              title: Text(l.serverMusicManagerVerify),
              additionalInfo: Text(l.serverMusicManagerVerifyHint),
              onTap: _active && !_controller.busy && _controller.stored
                  ? _verify
                  : null,
            ),
          ],
        ),
      ),
    ),
  ];

  List<Widget> _providers(AppLocalizations l, ServerMusicManager manager) => [
    SliverToBoxAdapter(
      child: _bounded(
        SettingsSection(
          header: Text(l.serverMusicManagerProviders),
          children: [
            for (final provider in manager.providers)
              SettingsActionTile(
                buttonKey: ValueKey(
                  'music-manager-provider-${provider.setupId}',
                ),
                leading: const Icon(CupertinoIcons.music_note),
                title: Text(_providerName(provider.domain)),
                additionalInfo: Text(
                  '${l.serverMusicRetainedRevision} ${provider.revision}',
                ),
                selected: _controller.selectedProviderId == provider.setupId,
                onTap: _active && _controller.verified && !_controller.busy
                    ? () => _controller.selectProvider(provider.setupId)
                    : null,
              ),
          ],
        ),
      ),
    ),
  ];

  List<Widget> _receivers(AppLocalizations l, ServerMusicManager manager) => [
    SliverToBoxAdapter(
      child: _bounded(
        SettingsSection(
          header: Text(l.serverMusicManagerReceivers),
          children: [
            for (final receiver in manager.receivers)
              SettingsActionTile(
                buttonKey: ValueKey('music-manager-receiver-${receiver.id}'),
                leading: Icon(
                  receiver.kind.startsWith('cast')
                      ? CupertinoIcons.tv
                      : CupertinoIcons.speaker_2,
                ),
                title: Text(receiver.name),
                additionalInfo: Text(
                  '${_receiverKind(l, receiver.kind)} · '
                  '${receiver.available && receiver.enabled ? l.serverMusicManagerAvailable : l.serverMusicManagerUnavailable}',
                ),
                selected: _controller.selectedReceiverId == receiver.id,
                onTap:
                    _active &&
                        _controller.verified &&
                        !_controller.busy &&
                        receiver.available &&
                        receiver.enabled
                    ? () => _controller.selectReceiver(receiver.id)
                    : null,
              ),
          ],
        ),
      ),
    ),
  ];

  List<Widget> _catalog(AppLocalizations l) => [
    SliverToBoxAdapter(
      child: _bounded(
        SettingsSection(
          header: Text(l.serverMusicManagerCatalog),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    label: l.serverMusicManagerSearch,
                    textField: true,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: CupertinoTextField(
                        key: const ValueKey('music-manager-search-field'),
                        controller: _search,
                        maxLength: 160,
                        placeholder: l.musicSearchPlaceholder,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _submitSearch,
                        padding: const EdgeInsets.all(14),
                        enabled:
                            _active &&
                            _controller.verified &&
                            !_controller.busy,
                      ),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: CupertinoButton(
                      key: const ValueKey('music-manager-search'),
                      minimumSize: const Size(48, 48),
                      onPressed:
                          _active && _controller.verified && !_controller.busy
                          ? () => _submitSearch(_search.text)
                          : null,
                      child: Text(l.serverMusicManagerSearch),
                    ),
                  ),
                ],
              ),
            ),
            if (_controller.catalog?.items.isEmpty == true)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l.serverMusicManagerNoResults),
              ),
            for (final item in _controller.catalog?.items ?? const [])
              SettingsActionTile(
                buttonKey: ValueKey('music-manager-item-${item.uri}'),
                leading: const Icon(CupertinoIcons.music_note_list),
                title: Text(item.name),
                additionalInfo: Text(
                  item.artists.isEmpty
                      ? item.mediaType
                      : item.artists.join(', '),
                ),
                selected: _controller.selectedMediaUri == item.uri,
                onTap: _active && _controller.verified && !_controller.busy
                    ? () => _controller.selectMedia(item.uri)
                    : null,
              ),
          ],
        ),
      ),
    ),
  ];

  Widget _action(
    String keyName,
    String label,
    ServerMusicOperation operation, {
    double? position,
  }) {
    final receiver = _controller.selectedReceiver;
    final needsMedia = {
      ServerMusicOperation.queueAdd,
      ServerMusicOperation.queueReplace,
    }.contains(operation);
    return CupertinoButton.filled(
      key: ValueKey('music-manager-$keyName'),
      minimumSize: const Size(48, 48),
      onPressed:
          _active &&
              _controller.verified &&
              !_controller.busy &&
              receiver?.supports(operation) == true &&
              (!needsMedia || _controller.selectedMedia != null)
          ? () => _command(operation, positionSeconds: position)
          : null,
      child: Text(label),
    );
  }

  List<Widget> _controls(AppLocalizations l) {
    final receiver = _controller.selectedReceiver;
    final queue = _controller.selectedQueue;
    return [
      SliverToBoxAdapter(
        child: _bounded(
          SettingsSection(
            header: Text(l.serverMusicManagerPlayback),
            footer: Text(l.serverMusicManagerReadbackHint),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      key: const ValueKey('music-manager-playback-heading'),
                      header: true,
                      liveRegion: true,
                      child: Text(
                        receiver?.name ?? l.serverMusicManagerChooseReceiver,
                        style: AppText.headline,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      receiver == null
                          ? l.serverMusicManagerChooseReceiver
                          : '${receiver.playbackState} · '
                                '${receiver.positionSeconds?.round() ?? 0}s',
                    ),
                    Text('${l.musicQueueCount}: ${queue?.itemCount ?? 0}'),
                    if (queue?.currentItemUri case final current?)
                      Text(
                        '${l.musicCurrentItem}: $current',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _action(
                          'play',
                          l.serverMusicManagerPlay,
                          ServerMusicOperation.play,
                        ),
                        _action(
                          'pause',
                          l.serverMusicManagerPause,
                          ServerMusicOperation.pause,
                        ),
                        _action(
                          'seek',
                          l.serverMusicManagerSeek,
                          ServerMusicOperation.seek,
                          position: ((receiver?.positionSeconds ?? 0) + 30)
                              .clamp(0, 864000)
                              .toDouble(),
                        ),
                        _action(
                          'queue-add',
                          l.serverMusicManagerAdd,
                          ServerMusicOperation.queueAdd,
                        ),
                        _action(
                          'queue-replace',
                          l.serverMusicManagerReplace,
                          ServerMusicOperation.queueReplace,
                        ),
                        _action(
                          'queue-clear',
                          l.serverMusicManagerClear,
                          ServerMusicOperation.queueClear,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (_active && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_active) _load();
      });
    }
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final manager = _controller.manager;
        return ServiceRootScaffold(
          title: l.serverMusicManagerTitle,
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Text(l.serverMusicManagerIntro),
                  ),
                ),
              ),
            ),
            if (!_active)
              SliverFilledMessage(child: Text(l.serverMusicRetainedAdminOnly))
            else ...[
              ..._status(l),
              if (_controller.busy)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                ),
              if (_controller.failure != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Semantics(
                      key: const ValueKey('music-manager-failure'),
                      liveRegion: true,
                      child: Text(l.serverMusicManagerFailure),
                    ),
                  ),
                ),
              if (manager != null) ...[
                ..._providers(l, manager),
                ..._receivers(l, manager),
                ..._catalog(l),
                ..._controls(l),
              ],
            ],
          ],
        );
      },
    );
  }
}
