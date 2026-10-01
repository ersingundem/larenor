import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../media/jellyfin/data/jellyfin_track_preferences_store.dart';
import '../../../media/jellyfin/domain/jellyfin_track_preferences.dart';
import '../../../media/jellyfin/presentation/player/jellyfin_player_screen.dart';
import '../../../media/local_audio/providers/local_audio_providers.dart';
import '../../data/server_account_controller.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';
import '../../media_segments/data/server_media_segment_controller.dart';
import '../../media_segments/domain/server_media_segment_models.dart';
import '../../providers/server_providers.dart';
import '../../watch_parties/data/server_watch_party_controller.dart';
import '../../watch_parties/domain/server_watch_party_models.dart';
import '../data/core_catalog_playback_capability_adapter.dart';
import '../data/core_catalog_player_source.dart';
import '../domain/core_catalog_player_binding.dart';

typedef CoreCatalogPlaybackCapabilityFactory =
    CoreCatalogPlaybackCapabilityAdapter Function(
      ServerAccountController account,
    );

final coreCatalogPlaybackCapabilityFactoryProvider =
    Provider<CoreCatalogPlaybackCapabilityFactory>(
      (_) =>
          (account) => CoreCatalogPlaybackCapabilityAdapter(account),
    );

/// Plays bytes selected through the verified Core catalog without ever
/// mounting a direct-home Jellyfin client.
final class CoreCatalogPlayerScreen extends ConsumerStatefulWidget {
  const CoreCatalogPlayerScreen({
    super.key,
    required this.page,
    required this.item,
  });

  final ServerMediaCatalogPage page;
  final ServerMediaCatalogItem item;

  @override
  ConsumerState<CoreCatalogPlayerScreen> createState() =>
      _CoreCatalogPlayerScreenState();
}

final class _CoreCatalogPlayerScreenState
    extends ConsumerState<CoreCatalogPlayerScreen>
    with WidgetsBindingObserver {
  static const _playerMutationTimeout = Duration(seconds: 5);
  late final ServerAccountController _account;
  late final int _accountGeneration;
  late final CoreCatalogPlayerBinding _binding;
  late final CoreCatalogPlayerSourcePort _source;
  late final CoreCatalogPlaybackCapabilityAdapter _capabilities;
  late final Player _player;
  late final ServerMediaSegmentController _segments;
  late final ServerWatchPartyController _watchParty;
  VideoController? _video;
  ValueListenable<TickerModeData>? _ticker;
  CoreCatalogPlayerLease? _lease;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<Duration>? _positionSubscription, _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  JellyfinTrackPreferenceRecord? _preferences;
  Duration _position = Duration.zero, _duration = Duration.zero;
  bool _playing = false, _applyingDirective = false;
  int _watchPartyRoundTripMs = 0;
  Timer? _watchPartyTimer;
  Future<void> _playerMutation = Future<void>.value();
  int _sourceEpoch = 0;
  int _generation = 0;
  bool _visible = true;
  bool _retired = false;
  bool _busy = false;
  String? _failure;

  bool get _active =>
      mounted &&
      !_retired &&
      _visible &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      !_account.hasPendingContext &&
      _account.session?.context != null &&
      _account.session?.sessionFamilyId != null &&
      _account.session?.authMutationPending == false &&
      _account.session?.user.mustChangePassword == false &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _binding = CoreCatalogPlayerBinding.fromCatalog(widget.page, widget.item);
    _source = ref.read(coreCatalogPlayerSourceFactoryProvider)(_account);
    _capabilities = ref.read(coreCatalogPlaybackCapabilityFactoryProvider)(
      _account,
    );
    _player = ref.read(jellyfinPlayerFactoryProvider)();
    _segments = ServerMediaSegmentController(_account)..addListener(_changed);
    _watchParty = ServerWatchPartyController(_account)
      ..addListener(_watchPartyChanged);
    _account.addListener(_accountChanged);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _watchPartyChanged() {
    if (_watchParty.snapshot == null) {
      _watchPartyTimer?.cancel();
      _watchPartyTimer = null;
    } else {
      _watchPartyTimer ??= Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_watchPartyTick()),
      );
    }
    if (mounted) setState(() {});
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

  void _accountChanged() {
    if (!_account.isCurrent(_accountGeneration) ||
        _account.session == null ||
        _account.hasPendingContext) {
      _retire();
    }
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _retire();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _retire();
  }

  Future<void> _closeLease({CoreCatalogPlayerLease? expected}) async {
    final retained = _lease;
    if (expected != null && !identical(retained, expected)) return;
    _lease = null;
    await retained?.close();
  }

  void _cancelPlaybackSubscriptions() {
    final tracks = _tracksSubscription;
    final position = _positionSubscription;
    final duration = _durationSubscription;
    final playing = _playingSubscription;
    _tracksSubscription = null;
    _positionSubscription = null;
    _durationSubscription = null;
    _playingSubscription = null;
    if (tracks != null) unawaited(tracks.cancel());
    if (position != null) unawaited(position.cancel());
    if (duration != null) unawaited(duration.cancel());
    if (playing != null) unawaited(playing.cancel());
  }

  void _resetPlaybackState() {
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _applyingDirective = false;
    _watchPartyRoundTripMs = 0;
  }

  void _retireWatchParty() {
    _watchParty.retire();
    _watchPartyTimer?.cancel();
    _watchPartyTimer = null;
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _generation++;
    _source.retire();
    _segments.retire();
    _retireWatchParty();
    _cancelPlaybackSubscriptions();
    _preferences = null;
    _resetPlaybackState();
    unawaited(_closeLease());
    unawaited(_ignoreFailure(_player.stop()));
    if (mounted) {
      setState(() {
        _busy = false;
        _failure = null;
      });
    }
  }

  Future<void> _ignoreFailure(Future<void> future) async {
    try {
      await future;
    } catch (_) {
      // Retirement remains fail-closed even when the native player is gone.
    }
  }

  Future<bool> _mutateCurrentPlayer({
    required int generation,
    required CoreCatalogPlayerLease lease,
    required Future<void> Function() effect,
  }) {
    final result = Completer<bool>();
    final previous = _playerMutation;
    _playerMutation = () async {
      await previous;
      if (!_playbackCurrent(generation, lease)) {
        result.complete(false);
        return;
      }
      try {
        await effect().timeout(_playerMutationTimeout);
      } on TimeoutException {
        // A timed-out native mutation can still complete later. Retiring this
        // player instance prevents that stale completion from reaching a
        // successor source opened on the same instance.
        _retire();
        result.complete(false);
        return;
      } catch (_) {
        result.complete(false);
        return;
      }
      result.complete(_playbackCurrent(generation, lease));
    }();
    return result.future;
  }

  Future<void> _drainPlayerMutations() async {
    await _playerMutation;
  }

  Future<void> _open(CoreCatalogPlayerSourceMode mode) async {
    if (!_active || _busy) return;
    final generation = ++_generation;
    bool current() => _active && generation == _generation;
    setState(() {
      _busy = true;
      _failure = null;
    });
    CoreCatalogPlayerLease? lease;
    try {
      await _drainPlayerMutations();
      if (!current()) return;
      final previous = _lease;
      if (previous != null) {
        _source.retire();
        _segments.retire();
        _retireWatchParty();
        _cancelPlaybackSubscriptions();
        _resetPlaybackState();
        _lease = null;
        await _ignoreFailure(_player.stop());
        await previous.close();
        if (!current()) return;
      }
      CoreCatalogPlaybackAuthorization? authorization;
      if (mode == CoreCatalogPlayerSourceMode.coreLease) {
        authorization = await _capabilities.observe(_binding, current: current);
        if (authorization == null ||
            !await _capabilities.revalidate(authorization, current: current)) {
          if (current()) _failure = 'source_unavailable';
          return;
        }
      }
      lease = await _source.open(
        _binding,
        mode: mode,
        authorization: authorization,
        current: current,
      );
      if (!current() || lease == null) {
        await lease?.close();
        return;
      }
      final selectedLease = lease;
      await ref.read(localAudioBridgeProvider).stopForVideo();
      if (!current()) {
        await selectedLease.close();
        return;
      }
      try {
        _preferences = await ref
            .read(jellyfinTrackPreferencesStoreProvider)
            .readCurrent(isCurrent: current);
      } catch (_) {
        _preferences = null;
      }
      if (!current()) {
        await selectedLease.close();
        return;
      }
      await _closeLease();
      _lease = selectedLease;
      final sourceEpoch = ++_sourceEpoch;
      await _tracksSubscription?.cancel();
      await _positionSubscription?.cancel();
      await _durationSubscription?.cancel();
      await _playingSubscription?.cancel();
      if (!current() || !identical(_lease, selectedLease)) {
        await selectedLease.close();
        return;
      }
      if (mounted) {
        setState(_resetPlaybackState);
      } else {
        _resetPlaybackState();
      }
      _tracksSubscription = _player.stream.tracks.listen(
        (tracks) =>
            unawaited(_applyPreferences(tracks, selectedLease, generation)),
      );
      unawaited(_watchInvalidation(selectedLease, generation));
      await _player.open(selectedLease.playable, play: true);
      if (!current()) {
        await _ignoreFailure(_player.stop());
        await _closeLease(expected: selectedLease);
        return;
      }
      _positionSubscription = _player.stream.position.listen((value) {
        if (mounted &&
            generation == _generation &&
            identical(_lease, selectedLease)) {
          setState(() => _position = value);
        }
      });
      _durationSubscription = _player.stream.duration.listen((value) {
        if (mounted &&
            generation == _generation &&
            identical(_lease, selectedLease)) {
          setState(() => _duration = value);
        }
      });
      _playingSubscription = _player.stream.playing.listen((value) {
        if (mounted &&
            generation == _generation &&
            identical(_lease, selectedLease)) {
          setState(() => _playing = value);
        }
      });
      unawaited(
        _segments.load(
          ServerMediaSegmentSource.fromCatalog(widget.page, widget.item),
          sourceEpoch: sourceEpoch,
          itemEpoch: _accountGeneration,
          current: current,
        ),
      );
    } catch (_) {
      if (lease != null && identical(_lease, lease)) {
        _lease = null;
        _segments.retire();
        _retireWatchParty();
        _cancelPlaybackSubscriptions();
        _preferences = null;
        _resetPlaybackState();
        await _ignoreFailure(_player.stop());
      }
      await lease?.close();
      if (current()) _failure = 'source_unavailable';
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  bool get _watchPartyCurrent => _active && _lease != null && !_busy;

  bool _playbackCurrent(int generation, CoreCatalogPlayerLease lease) =>
      _watchPartyCurrent &&
      generation == _generation &&
      identical(_lease, lease);

  bool _watchSnapshotCurrent(
    int generation,
    CoreCatalogPlayerLease lease,
    ServerWatchPartySnapshot snapshot,
  ) =>
      _playbackCurrent(generation, lease) &&
      identical(_watchParty.snapshot, snapshot);

  Future<void> _watchPartyTick() async {
    final family = _account.session?.sessionFamilyId;
    final snapshot = _watchParty.snapshot;
    final lease = _lease;
    final generation = _generation;
    if (snapshot == null ||
        lease == null ||
        family == null ||
        _watchParty.busy ||
        !_watchSnapshotCurrent(generation, lease, snapshot)) {
      return;
    }
    if (_watchParty.failure == 'watch_party_authority_changed') {
      await _watchParty.refresh(
        current: () => _watchSnapshotCurrent(generation, lease, snapshot),
      );
      return;
    }
    final stopwatch = Stopwatch()..start();
    await _watchParty.report(
      target: ServerWatchPartyTarget(
        targetId: family,
        targetRevision: _sourceEpoch + 1,
        canSeek: true,
        canPause: true,
      ),
      playback: ServerWatchPartyPlayback(
        state: _playing
            ? ServerWatchPartyPlaybackState.playing
            : ServerWatchPartyPlaybackState.paused,
        positionMs: _position.inMilliseconds,
        measuredRoundTripMs: _watchPartyRoundTripMs,
      ),
      current: () => _watchSnapshotCurrent(generation, lease, snapshot),
    );
    if (!_playbackCurrent(generation, lease)) return;
    stopwatch.stop();
    _watchPartyRoundTripMs = stopwatch.elapsedMilliseconds.clamp(0, 10000);
    await _applyDirective();
  }

  Future<void> _applyDirective() async {
    final snapshot = _watchParty.snapshot;
    final directive = snapshot?.directive;
    final lease = _lease;
    final generation = _generation;
    if (directive == null ||
        snapshot == null ||
        lease == null ||
        directive.action == ServerWatchPartyDirectiveAction.none ||
        directive.action == ServerWatchPartyDirectiveAction.unsupported ||
        _applyingDirective ||
        !_watchSnapshotCurrent(generation, lease, snapshot)) {
      return;
    }
    bool current() => _watchSnapshotCurrent(generation, lease, snapshot);
    _applyingDirective = true;
    try {
      switch (directive.action) {
        case ServerWatchPartyDirectiveAction.pause:
          await _mutateCurrentPlayer(
            generation: generation,
            lease: lease,
            effect: () async {
              await _player.seek(Duration(milliseconds: directive.positionMs));
              if (current()) await _player.pause();
            },
          );
        case ServerWatchPartyDirectiveAction.play:
        case ServerWatchPartyDirectiveAction.seekAndPlay:
          await _mutateCurrentPlayer(
            generation: generation,
            lease: lease,
            effect: () async {
              await _player.seek(Duration(milliseconds: directive.positionMs));
              if (current()) await _player.play();
            },
          );
        case ServerWatchPartyDirectiveAction.none:
        case ServerWatchPartyDirectiveAction.unsupported:
          break;
      }
    } finally {
      if (generation == _generation && identical(_lease, lease)) {
        _applyingDirective = false;
      }
    }
  }

  bool get _canControlPlayback {
    if (!_watchPartyCurrent) return false;
    final snapshot = _watchParty.snapshot;
    return snapshot == null ||
        !_watchParty.busy &&
            snapshot.leaderAccountId == _account.session?.user.id;
  }

  Future<void> _publishLeaderCommand({
    required String action,
    required Duration position,
    required int generation,
    required CoreCatalogPlayerLease lease,
    required ServerWatchPartySnapshot? snapshot,
  }) async {
    if (snapshot == null ||
        snapshot.leaderAccountId != _account.session?.user.id ||
        !_watchSnapshotCurrent(generation, lease, snapshot)) {
      return;
    }
    await _watchParty.command(
      action: action,
      position: position,
      current: () => _watchSnapshotCurrent(generation, lease, snapshot),
    );
  }

  Future<void> _togglePlayback() async {
    final lease = _lease;
    final generation = _generation;
    final snapshot = _watchParty.snapshot;
    if (lease == null || !_canControlPlayback) return;
    if (_playing) {
      final applied = await _mutateCurrentPlayer(
        generation: generation,
        lease: lease,
        effect: _player.pause,
      );
      if (!applied) return;
      await _publishLeaderCommand(
        action: 'pause',
        position: _position,
        generation: generation,
        lease: lease,
        snapshot: snapshot,
      );
    } else {
      final applied = await _mutateCurrentPlayer(
        generation: generation,
        lease: lease,
        effect: _player.play,
      );
      if (!applied) return;
      await _publishLeaderCommand(
        action: 'play',
        position: _position,
        generation: generation,
        lease: lease,
        snapshot: snapshot,
      );
    }
  }

  Future<void> _seekBy(Duration delta) async {
    final lease = _lease;
    final generation = _generation;
    final snapshot = _watchParty.snapshot;
    if (lease == null || !_canControlPlayback || _duration <= Duration.zero) {
      return;
    }
    final positionMs = (_position + delta).inMilliseconds.clamp(
      0,
      _duration.inMilliseconds,
    );
    final target = Duration(milliseconds: positionMs);
    final applied = await _mutateCurrentPlayer(
      generation: generation,
      lease: lease,
      effect: () => _player.seek(target),
    );
    if (!applied) return;
    await _publishLeaderCommand(
      action: _playing ? 'play' : 'pause',
      position: target,
      generation: generation,
      lease: lease,
      snapshot: snapshot,
    );
  }

  Future<void> _createWatchParty() => _watchParty.createCurrentItem(
    _binding.itemId,
    current: () => _watchPartyCurrent,
  );

  Future<void> _joinWatchParty() async {
    final lifecycle = _generation;
    final controller = TextEditingController();
    final value = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(AppLocalizations.of(context).jellyfinWatchPartyJoin),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            key: const ValueKey('core-catalog-player-watch-party-code'),
            controller: controller,
            autocorrect: false,
            placeholder: AppLocalizations.of(context).jellyfinWatchPartyCode,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(AppLocalizations.of(context).jellyfinWatchPartyJoin),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || lifecycle != _generation || !_watchPartyCurrent) {
      return;
    }
    await _watchParty.join(
      value,
      itemId: _binding.itemId,
      current: () => lifecycle == _generation && _watchPartyCurrent,
    );
  }

  ServerMediaSegment? get _activeSegment {
    final result = _segments.result;
    if (result == null ||
        !result.isCurrent(
          sourceEpoch: _sourceEpoch,
          itemEpoch: _accountGeneration,
        ) ||
        _duration <= Duration.zero) {
      return null;
    }
    final segment = result.segmentAt(_position);
    if (segment == null || segment.end > _duration) return null;
    return segment;
  }

  Future<void> _skip(ServerMediaSegment expected) async {
    final current = _activeSegment;
    final lease = _lease;
    final generation = _generation;
    final snapshot = _watchParty.snapshot;
    if (current == null ||
        lease == null ||
        !_canControlPlayback ||
        current.kind != expected.kind ||
        current.start != expected.start ||
        current.end != expected.end) {
      return;
    }
    final applied = await _mutateCurrentPlayer(
      generation: generation,
      lease: lease,
      effect: () => _player.seek(current.end),
    );
    if (!applied) return;
    await _publishLeaderCommand(
      action: _playing ? 'play' : 'pause',
      position: current.end,
      generation: generation,
      lease: lease,
      snapshot: snapshot,
    );
  }

  Future<void> _applyPreferences(
    Tracks tracks,
    CoreCatalogPlayerLease lease,
    int generation,
  ) async {
    if (!_active || generation != _generation || !identical(_lease, lease)) {
      return;
    }
    final preferred = _preferences;
    if (preferred == null) return;
    final audio = JellyfinTrackPreferences.audio(
      tracks.audio,
      preferred.audioLanguage,
    );
    if (audio != null &&
        generation == _generation &&
        identical(_lease, lease)) {
      await _mutateCurrentPlayer(
        generation: generation,
        lease: lease,
        effect: () => _player.setAudioTrack(audio),
      );
    }
    if (generation != _generation || !identical(_lease, lease)) return;
    final subtitle = JellyfinTrackPreferences.subtitle(
      tracks.subtitle,
      preferred.subtitleLanguage,
    );
    if (subtitle != null) {
      await _mutateCurrentPlayer(
        generation: generation,
        lease: lease,
        effect: () => _player.setSubtitleTrack(subtitle),
      );
    }
  }

  Future<void> _watchInvalidation(
    CoreCatalogPlayerLease lease,
    int generation,
  ) async {
    final reason = await lease.invalidated;
    if (!mounted ||
        generation != _generation ||
        !identical(_lease, lease) ||
        reason == 'retired') {
      return;
    }
    final cleanupGeneration = ++_generation;
    _busy = true;
    _lease = null;
    _source.retire();
    _segments.retire();
    _retireWatchParty();
    _cancelPlaybackSubscriptions();
    _preferences = null;
    _resetPlaybackState();
    await _drainPlayerMutations();
    await _ignoreFailure(_player.stop());
    await lease.close();
    if (mounted && cleanupGeneration == _generation && _lease == null) {
      setState(() {
        _busy = false;
        _failure = reason;
      });
    }
  }

  Widget _playbackControls(AppLocalizations l, {required bool isTurkish}) =>
      Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Semantics(
                button: true,
                label: isTurkish
                    ? '10 saniye geri sar'
                    : 'Seek backward 10 seconds',
                child: CupertinoButton(
                  key: const ValueKey('core-catalog-player-seek-backward'),
                  onPressed: _canControlPlayback && _duration > Duration.zero
                      ? () => _seekBy(const Duration(seconds: -10))
                      : null,
                  child: const Icon(CupertinoIcons.gobackward_10),
                ),
              ),
              Semantics(
                button: true,
                toggled: _playing,
                label: _playing
                    ? (isTurkish ? 'Duraklat' : 'Pause')
                    : l.jellyfinPlayButton,
                child: CupertinoButton(
                  key: const ValueKey('core-catalog-player-toggle-playback'),
                  onPressed: _canControlPlayback ? _togglePlayback : null,
                  child: Icon(
                    _playing
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill,
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: isTurkish
                    ? '10 saniye ileri sar'
                    : 'Seek forward 10 seconds',
                child: CupertinoButton(
                  key: const ValueKey('core-catalog-player-seek-forward'),
                  onPressed: _canControlPlayback && _duration > Duration.zero
                      ? () => _seekBy(const Duration(seconds: 10))
                      : null,
                  child: const Icon(CupertinoIcons.goforward_10),
                ),
              ),
            ],
          ),
          Text(
            '${_position.inMinutes.toString().padLeft(2, '0')}:'
            '${(_position.inSeconds % 60).toString().padLeft(2, '0')} / '
            '${_duration.inMinutes.toString().padLeft(2, '0')}:'
            '${(_duration.inSeconds % 60).toString().padLeft(2, '0')}',
            textAlign: TextAlign.center,
            style: AppText.footnote,
          ),
        ],
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _segments.removeListener(_changed);
    _segments.dispose();
    _watchParty.removeListener(_watchPartyChanged);
    _watchParty.dispose();
    _watchPartyTimer?.cancel();
    _generation++;
    _source.dispose();
    _cancelPlaybackSubscriptions();
    unawaited(_closeLease());
    unawaited(_player.stop());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isTurkish = Localizations.localeOf(context).languageCode == 'tr';
    final activeSegment = _activeSegment;
    final onlineAvailable = ref.watch(
      coreCatalogOnlinePlaybackAvailableProvider,
    );
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(_binding.title)),
      child: SafeArea(
        child: ListView(
          key: ValueKey(
            _lease == null
                ? 'core-catalog-player-idle'
                : 'core-catalog-player-active',
          ),
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
            if (_lease != null) ...[
              const SizedBox(height: 8),
              _playbackControls(l, isTurkish: isTurkish),
            ],
            const SizedBox(height: 16),
            Text(_binding.title, style: AppText.title2),
            const SizedBox(height: 8),
            Text(l.jellyfinOfflineMediaHint, style: AppText.body),
            if (_failure != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(l.mediaReadFailedTitle, style: AppText.body),
              ),
            ],
            const SizedBox(height: 16),
            if (activeSegment != null) ...[
              CupertinoButton(
                key: const ValueKey('core-catalog-player-skip-segment'),
                onPressed: _canControlPlayback
                    ? () => _skip(activeSegment)
                    : null,
                child: Text(
                  activeSegment.kind == ServerMediaSegmentKind.intro
                      ? l.jellyfinPlayerSkipIntro
                      : l.jellyfinPlayerSkipOutro,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_lease != null) ...[
              const SizedBox(height: 8),
              Text(l.jellyfinWatchPartyHint, style: AppText.footnote),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: CupertinoButton(
                      key: const ValueKey(
                        'core-catalog-player-watch-party-create',
                      ),
                      onPressed: _watchParty.busy ? null : _createWatchParty,
                      child: Text(l.jellyfinWatchPartyCreate),
                    ),
                  ),
                  Expanded(
                    child: CupertinoButton(
                      key: const ValueKey(
                        'core-catalog-player-watch-party-join',
                      ),
                      onPressed: _watchParty.busy ? null : _joinWatchParty,
                      child: Text(l.jellyfinWatchPartyJoin),
                    ),
                  ),
                ],
              ),
              if (_watchParty.invitation case final invitation?)
                SelectableText(invitation.value, style: AppText.footnote),
              const SizedBox(height: 8),
            ],
            if (onlineAvailable) ...[
              CupertinoButton.filled(
                key: const ValueKey('core-catalog-player-open-online'),
                onPressed: _active && !_busy
                    ? () => _open(CoreCatalogPlayerSourceMode.coreLease)
                    : null,
                child: Text(l.jellyfinPlayButton),
              ),
              const SizedBox(height: 10),
            ],
            CupertinoButton.filled(
              key: const ValueKey('core-catalog-player-open-source'),
              onPressed: _active && !_busy
                  ? () => _open(CoreCatalogPlayerSourceMode.offlineVault)
                  : null,
              child: _busy
                  ? const CupertinoActivityIndicator()
                  : Text(l.jellyfinOfflineMediaDownload),
            ),
          ],
        ),
      ),
    );
  }
}
