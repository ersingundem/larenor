import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../shared/theme/typography.dart';
import '../../../media/jellyfin/presentation/player/jellyfin_player_screen.dart';
import '../../../media/local_audio/providers/local_audio_providers.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_local_media_scope.dart';
import '../../providers/server_providers.dart';
import '../data/server_offline_media_controller.dart';
import '../data/server_offline_media_vault.dart';
import '../domain/server_offline_media_models.dart';

final class _LocalIoCancelled implements Exception {
  const _LocalIoCancelled();
}

final class _OwnedLocalIoDeadline<T> {
  _OwnedLocalIoDeadline(Future<T> operation, Duration timeout) {
    _timer = Timer(timeout, () {
      if (!_result.isCompleted) {
        _result.completeError(TimeoutException('local I/O deadline exceeded'));
      }
    });
    operation.then(
      (value) {
        _timer.cancel();
        if (!_result.isCompleted) _result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        _timer.cancel();
        if (!_result.isCompleted) _result.completeError(error, stackTrace);
      },
    );
  }

  final Completer<T> _result = Completer<T>();
  late final Timer _timer;

  Future<T> get future => _result.future;

  void cancel() {
    _timer.cancel();
    if (!_result.isCompleted) {
      _result.completeError(const _LocalIoCancelled());
    }
  }
}

final class ServerOfflineDownloadsScreen extends ConsumerStatefulWidget {
  const ServerOfflineDownloadsScreen({
    super.key,
    required this.scope,
    this.vault,
    this.source,
    this.localIoTimeout = const Duration(minutes: 10),
    this.playerOperationTimeout = const Duration(seconds: 5),
  }) : assert(localIoTimeout > Duration.zero),
       assert(playerOperationTimeout > Duration.zero);

  final ServerLocalMediaScope scope;
  final ServerOfflineMediaVault? vault;
  final ServerOfflineDownloadsPort? source;
  final Duration localIoTimeout;
  final Duration playerOperationTimeout;

  @override
  ConsumerState<ServerOfflineDownloadsScreen> createState() =>
      _ServerOfflineDownloadsScreenState();
}

abstract base class ServerOfflineDownloadsPort {
  Future<List<ServerOfflineMediaManifest>> completed(
    ServerLocalMediaScope scope, {
    required bool Function() current,
  });

  Future<Uri?> open(
    ServerLocalMediaScope scope,
    ServerOfflineMediaManifest manifest, {
    required bool Function() current,
  });

  Future<void> closePlayback();
  void retire({required bool purge});
  void dispose();
}

final class _ControllerOfflineDownloadsPort extends ServerOfflineDownloadsPort {
  _ControllerOfflineDownloadsPort(
    ServerAccountController account,
    ServerLocalMediaScope scope, {
    ServerOfflineMediaVault? vault,
  }) : _controller = ServerOfflineMediaController.local(
         account,
         scope,
         vault: vault,
       );

  final ServerOfflineMediaController _controller;

  @override
  Future<List<ServerOfflineMediaManifest>> completed(
    ServerLocalMediaScope scope, {
    required bool Function() current,
  }) => _controller.completedForLocalScope(scope, current: current);

  @override
  Future<Uri?> open(
    ServerLocalMediaScope scope,
    ServerOfflineMediaManifest manifest, {
    required bool Function() current,
  }) =>
      _controller.openCompletedForLocalScope(scope, manifest, current: current);

  @override
  Future<void> closePlayback() => _controller.closePlayback();

  @override
  void retire({required bool purge}) {
    // The local controller observes the account directly and owns the
    // authoritative purge. The screen only needs to suspend playback while an
    // account transition is still retryable.
    if (!purge) _controller.retire();
  }

  @override
  void dispose() => _controller.dispose();
}

final class _ServerOfflineDownloadsScreenState
    extends ConsumerState<ServerOfflineDownloadsScreen> {
  late final ServerAccountController _account;
  late final ServerOfflineDownloadsPort _offline;
  var _generation = 0;
  var _loading = true;
  var _retired = false;
  String? _failure;
  List<ServerOfflineMediaManifest> _items = const [];
  _OwnedLocalIoDeadline<List<ServerOfflineMediaManifest>>? _inventoryDeadline;

  bool get _current =>
      mounted &&
      !_retired &&
      !_account.working &&
      !_account.hasPendingContext &&
      _account.localMediaScope == widget.scope;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _offline =
        widget.source ??
        _ControllerOfflineDownloadsPort(
          _account,
          widget.scope,
          vault: widget.vault,
        );
    _account.addListener(_accountChanged);
    unawaited(_load());
  }

  void _accountChanged() {
    if (_retired) return;
    final current = _account.localMediaScope;
    if (current == widget.scope && !_account.working) {
      if (_failure == 'offline_scope_suspended') unawaited(_load());
      return;
    }
    _cancelInventoryDeadline();
    _generation++;
    final transient = _account.working || _account.hasPendingContext;
    _offline.retire(purge: !transient);
    if (transient) {
      if (mounted) {
        setState(() {
          _loading = false;
          _items = const [];
          _failure = 'offline_scope_suspended';
        });
      }
      return;
    }
    _retired = true;
    if (mounted) {
      setState(() {
        _loading = false;
        _items = const [];
        _failure = 'offline_scope_retired';
      });
    }
  }

  Future<void> _load() async {
    _cancelInventoryDeadline();
    final generation = ++_generation;
    bool current() => _current && generation == _generation;
    if (!_current) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = 'offline_scope_suspended';
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _failure = null;
    });
    final deadline = _OwnedLocalIoDeadline(
      _offline.completed(widget.scope, current: current),
      widget.localIoTimeout,
    );
    _inventoryDeadline = deadline;
    try {
      final items = await deadline.future;
      if (!current()) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on _LocalIoCancelled {
      return;
    } on TimeoutException {
      if (!current()) return;
      _generation++;
      setState(() {
        _items = const [];
        _loading = false;
        _failure = 'offline_media_timeout';
      });
    } catch (_) {
      if (!current()) return;
      setState(() {
        _items = const [];
        _loading = false;
        _failure = 'offline_media_integrity_failed';
      });
    } finally {
      if (identical(_inventoryDeadline, deadline)) {
        _inventoryDeadline = null;
      }
    }
  }

  void _cancelInventoryDeadline() {
    _inventoryDeadline?.cancel();
    _inventoryDeadline = null;
  }

  Future<void> _open(ServerOfflineMediaManifest manifest) async {
    if (!_current || _loading) return;
    await Navigator.of(context).push<void>(
      CupertinoPageRoute(
        builder: (_) => _ServerOfflinePlaybackScreen(
          account: _account,
          offline: _offline,
          scope: widget.scope,
          manifest: manifest,
          localIoTimeout: widget.localIoTimeout,
          playerOperationTimeout: widget.playerOperationTimeout,
        ),
      ),
    );
    if (_current) unawaited(_load());
  }

  @override
  void dispose() {
    _cancelInventoryDeadline();
    _generation++;
    _account.removeListener(_accountChanged);
    _offline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _OfflineCopy.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(copy.downloadsTitle)),
      child: SafeArea(
        child: _loading
            ? Center(
                child: Semantics(
                  label: copy.loading,
                  child: const CupertinoActivityIndicator(
                    key: ValueKey('offline-downloads-loading'),
                  ),
                ),
              )
            : _failure != null
            ? _FailureBody(
                copy: copy,
                retry: _retired ? null : _load,
                suspended: _failure == 'offline_scope_suspended',
              )
            : _items.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    copy.empty,
                    key: const ValueKey('offline-downloads-empty'),
                    textAlign: TextAlign.center,
                    style: AppText.body,
                  ),
                ),
              )
            : ListView.separated(
                key: const ValueKey('offline-downloads-list'),
                padding: const EdgeInsets.all(16),
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return Semantics(
                    button: true,
                    label: '${copy.play}: ${item.title}',
                    child: CupertinoListTile(
                      key: ValueKey('offline-download-${item.grantId}'),
                      title: Text(item.title),
                      subtitle: Text(
                        copy.storedSize(item.contentLength),
                        style: AppText.footnote,
                      ),
                      trailing: const Icon(CupertinoIcons.play_circle_fill),
                      onTap: _current ? () => _open(item) : null,
                    ),
                  );
                },
              ),
      ),
    );
  }
}

final class _FailureBody extends StatelessWidget {
  const _FailureBody({
    required this.copy,
    required this.retry,
    required this.suspended,
  });

  final _OfflineCopy copy;
  final VoidCallback? retry;
  final bool suspended;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              suspended ? copy.suspended : copy.unavailable,
              key: const ValueKey('offline-downloads-error'),
              textAlign: TextAlign.center,
              style: AppText.body,
            ),
          ),
          if (retry != null) ...[
            const SizedBox(height: 12),
            CupertinoButton(
              key: const ValueKey('offline-downloads-retry'),
              onPressed: retry,
              child: Text(copy.retry),
            ),
          ],
        ],
      ),
    ),
  );
}

final class _ServerOfflinePlaybackScreen extends ConsumerStatefulWidget {
  const _ServerOfflinePlaybackScreen({
    required this.account,
    required this.offline,
    required this.scope,
    required this.manifest,
    required this.localIoTimeout,
    required this.playerOperationTimeout,
  });

  final ServerAccountController account;
  final ServerOfflineDownloadsPort offline;
  final ServerLocalMediaScope scope;
  final ServerOfflineMediaManifest manifest;
  final Duration localIoTimeout;
  final Duration playerOperationTimeout;

  @override
  ConsumerState<_ServerOfflinePlaybackScreen> createState() =>
      _ServerOfflinePlaybackScreenState();
}

final class _ServerOfflinePlaybackScreenState
    extends ConsumerState<_ServerOfflinePlaybackScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  VideoController? _video;
  StreamSubscription<Duration>? _positionSubscription, _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<String>? _errorSubscription;
  Future<void> _playerMutation = Future<void>.value();
  Future<void>? _shutdown;
  var _generation = 0;
  var _loading = true;
  var _retired = false;
  var _disposed = false;
  var _playing = false;
  var _position = Duration.zero;
  var _duration = Duration.zero;
  String? _failure;
  _OwnedLocalIoDeadline<Uri?>? _localIoDeadline;

  bool get _current =>
      mounted &&
      !_disposed &&
      !_retired &&
      widget.account.localMediaScope == widget.scope &&
      (ModalRoute.of(context)?.isCurrent ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = ref.read(jellyfinPlayerFactoryProvider)();
    widget.account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  void _accountChanged() {
    if (widget.account.localMediaScope != widget.scope) _retire();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _retire();
  }

  Future<void> _open() async {
    _cancelLocalIoDeadline();
    final generation = ++_generation;
    bool current() => _current && generation == _generation;
    final deadline = _OwnedLocalIoDeadline(
      widget.offline.open(widget.scope, widget.manifest, current: current),
      widget.localIoTimeout,
    );
    _localIoDeadline = deadline;
    try {
      final uri = await deadline.future;
      if (!current()) {
        await _closeOfflineBounded();
        return;
      }
      if (uri == null) {
        await _closeOfflineBounded();
        if (current()) {
          setState(() {
            _loading = false;
            _failure = 'offline_media_unavailable';
          });
        }
        return;
      }
      await ref
          .read(localAudioBridgeProvider)
          .stopForVideo()
          .timeout(widget.playerOperationTimeout);
      if (!current()) {
        await _closeOfflineBounded();
        return;
      }
      _positionSubscription = _player.stream.position.listen((value) {
        if (current()) {
          setState(() => _position = value);
        }
      });
      _durationSubscription = _player.stream.duration.listen((value) {
        if (current()) {
          setState(() => _duration = value);
        }
      });
      _playingSubscription = _player.stream.playing.listen((value) {
        if (current()) {
          setState(() => _playing = value);
        }
      });
      _errorSubscription = _player.stream.error.listen((_) {
        if (current()) _retire(failure: 'offline_media_unavailable');
      });
      final opened = await _mutateCurrentPlayer(
        generation: generation,
        current: current,
        effect: () => _player.open(Media(uri.toString()), play: true),
      );
      if (opened && current()) setState(() => _loading = false);
    } on _LocalIoCancelled {
      await _closeOfflineBounded();
    } on TimeoutException {
      if (current()) {
        _generation++;
        _retire(failure: 'offline_media_unavailable');
      } else {
        await _closeOfflineBounded();
      }
    } catch (_) {
      if (current()) {
        _retire(failure: 'offline_media_unavailable');
      } else {
        await _closeOfflineBounded();
      }
    } finally {
      if (identical(_localIoDeadline, deadline)) {
        _localIoDeadline = null;
      }
    }
  }

  void _cancelLocalIoDeadline() {
    _localIoDeadline?.cancel();
    _localIoDeadline = null;
  }

  Future<void> _closeOfflineBounded() async {
    try {
      await widget.offline.closePlayback().timeout(
        widget.playerOperationTimeout,
      );
    } catch (_) {
      // The local scope is already retired; a vanished lease cannot revive it.
    }
  }

  Future<bool> _mutateCurrentPlayer({
    required int generation,
    required bool Function() current,
    required Future<void> Function() effect,
  }) {
    final result = Completer<bool>();
    final previous = _playerMutation;
    _playerMutation = () async {
      try {
        await previous;
      } catch (_) {
        // Every owned mutation is fail-closed below. A prior failure must not
        // let this operation escape the current-generation check.
      }
      if (!current() || generation != _generation) {
        result.complete(false);
        return;
      }
      Future<void>? operation;
      try {
        operation = effect();
        await operation.timeout(widget.playerOperationTimeout);
      } on TimeoutException {
        final late = operation;
        if (late != null) {
          unawaited(
            late.then((_) {
              if (!current() && !_disposed) {
                unawaited(_enqueuePlayerFence());
              }
            }, onError: (_, _) {}),
          );
        }
        if (current()) _retire(failure: 'offline_media_unavailable');
        result.complete(false);
        return;
      } catch (_) {
        if (current()) _retire(failure: 'offline_media_unavailable');
        result.complete(false);
        return;
      }
      result.complete(current() && generation == _generation);
    }();
    return result.future;
  }

  Future<void> _cancelPlaybackSubscriptions() async {
    final subscriptions = <StreamSubscription<dynamic>?>[
      _positionSubscription,
      _durationSubscription,
      _playingSubscription,
      _errorSubscription,
    ];
    _positionSubscription = null;
    _durationSubscription = null;
    _playingSubscription = null;
    _errorSubscription = null;
    for (final subscription in subscriptions) {
      if (subscription == null) continue;
      try {
        await subscription.cancel().timeout(widget.playerOperationTimeout);
      } catch (_) {
        // Retirement proceeds even if a native stream is already unavailable.
      }
    }
  }

  Future<void> _enqueuePlayerFence() {
    final previous = _playerMutation;
    final fenced = () async {
      try {
        await previous;
      } catch (_) {}
      try {
        await _player.stop().timeout(widget.playerOperationTimeout);
      } catch (_) {
        // The generation fence remains authoritative if native stop is gone.
      }
      await _closeOfflineBounded();
    }();
    _playerMutation = fenced;
    return fenced;
  }

  Future<void> _shutdownPlayback() => _shutdown ??= () async {
    await _cancelPlaybackSubscriptions();
    await _enqueuePlayerFence();
  }();

  void _retire({String failure = 'offline_scope_retired'}) {
    if (_retired) return;
    _retired = true;
    _cancelLocalIoDeadline();
    _generation++;
    unawaited(_shutdownPlayback());
    if (mounted && !_disposed) {
      setState(() {
        _loading = false;
        _failure = failure;
      });
    }
  }

  Future<void> _toggle() async {
    if (!_current || _loading || _failure != null) return;
    final generation = _generation;
    bool current() => _current && generation == _generation;
    final pause = _playing;
    await _mutateCurrentPlayer(
      generation: generation,
      current: current,
      effect: pause ? _player.pause : _player.play,
    );
  }

  Future<void> _seek(Duration delta) async {
    if (!_current || _duration <= Duration.zero || _failure != null) return;
    final target = Duration(
      milliseconds: (_position + delta).inMilliseconds.clamp(
        0,
        _duration.inMilliseconds,
      ),
    );
    final generation = _generation;
    bool current() => _current && generation == _generation;
    await _mutateCurrentPlayer(
      generation: generation,
      current: current,
      effect: () => _player.seek(target),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelLocalIoDeadline();
    WidgetsBinding.instance.removeObserver(this);
    widget.account.removeListener(_accountChanged);
    if (!_retired) {
      _retired = true;
      _generation++;
    }
    final shutdown = _shutdownPlayback();
    unawaited(() async {
      await shutdown;
      try {
        await _player.dispose().timeout(widget.playerOperationTimeout);
      } catch (_) {
        // Disposal is last and bounded; no successor uses this player instance.
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _OfflineCopy.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.manifest.title),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CupertinoColors.black,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ref.read(jellyfinVideoSurfaceProvider)(
                    () => _video ??= VideoController(_player),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(widget.manifest.title, style: AppText.title2),
            const SizedBox(height: 12),
            if (_loading)
              Semantics(
                label: copy.loading,
                child: const Center(
                  child: CupertinoActivityIndicator(
                    key: ValueKey('offline-player-loading'),
                  ),
                ),
              )
            else if (_failure != null)
              Semantics(
                liveRegion: true,
                child: Column(
                  children: [
                    Text(
                      copy.unavailable,
                      key: const ValueKey('offline-player-error'),
                      textAlign: TextAlign.center,
                      style: AppText.body,
                    ),
                    const SizedBox(height: 12),
                    CupertinoButton(
                      key: const ValueKey('offline-player-retry'),
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: Text(copy.retry),
                    ),
                  ],
                ),
              )
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Semantics(
                    button: true,
                    label: copy.seekBack,
                    child: CupertinoButton(
                      key: const ValueKey('offline-player-seek-back'),
                      onPressed: _duration > Duration.zero
                          ? () => _seek(const Duration(seconds: -10))
                          : null,
                      child: const Icon(CupertinoIcons.gobackward_10),
                    ),
                  ),
                  Semantics(
                    button: true,
                    toggled: _playing,
                    label: _playing ? copy.pause : copy.play,
                    child: CupertinoButton(
                      key: const ValueKey('offline-player-toggle'),
                      onPressed: _toggle,
                      child: Icon(
                        _playing
                            ? CupertinoIcons.pause_fill
                            : CupertinoIcons.play_fill,
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: copy.seekForward,
                    child: CupertinoButton(
                      key: const ValueKey('offline-player-seek-forward'),
                      onPressed: _duration > Duration.zero
                          ? () => _seek(const Duration(seconds: 10))
                          : null,
                      child: const Icon(CupertinoIcons.goforward_10),
                    ),
                  ),
                ],
              ),
              Text(
                '${_clock(_position)} / ${_clock(_duration)}',
                key: const ValueKey('offline-player-position'),
                textAlign: TextAlign.center,
                style: AppText.footnote,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _clock(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:'
      '${(value.inSeconds % 60).toString().padLeft(2, '0')}';
}

final class _OfflineCopy {
  const _OfflineCopy({required this.tr});

  factory _OfflineCopy.of(BuildContext context) =>
      _OfflineCopy(tr: Localizations.localeOf(context).languageCode == 'tr');

  final bool tr;
  String get downloadsTitle =>
      tr ? 'Çevrimdışı indirmeler' : 'Offline downloads';
  String get loading => tr ? 'İndirilenler yükleniyor' : 'Loading downloads';
  String get empty => tr
      ? 'Bu hesap için bu tablette tamamlanmış indirme yok.'
      : 'There are no completed downloads for this account on this tablet.';
  String get unavailable => tr
      ? 'Şifreli indirme doğrulanamadı. Dosya oynatılmadı.'
      : 'The encrypted download could not be verified. Nothing was played.';
  String get suspended => tr
      ? 'Hesap değişikliği tamamlanana kadar çevrimdışı medya kapalı.'
      : 'Offline media is unavailable until the account change finishes.';
  String get retry => tr ? 'Yeniden dene' : 'Try again';
  String get play => tr ? 'İndirileni oynat' : 'Play download';
  String get pause => tr ? 'Duraklat' : 'Pause';
  String get seekBack => tr ? '10 saniye geri sar' : 'Seek backward 10 seconds';
  String get seekForward =>
      tr ? '10 saniye ileri sar' : 'Seek forward 10 seconds';
  String storedSize(int bytes) => tr
      ? 'Bu tablette şifreli • ${_megabytes(bytes)} MB'
      : 'Encrypted on this tablet • ${_megabytes(bytes)} MB';

  static String _megabytes(int bytes) => (bytes / (1024 * 1024))
      .clamp(0, 999999)
      .toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0);
}
