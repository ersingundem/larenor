import 'dart:async';

import '../../../../../core/idle_prevention.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../../../../../core/app_interaction_scope.dart';
import '../../../../../l10n/generated/app_localizations.dart';
import '../../data/jellyfin_client.dart';
import '../../data/jellyfin_track_preferences_store.dart';
import '../../data/legacy_jellyfin_track_preferences_controller.dart';
import '../../data/legacy_jellyfin_track_preferences_preview.dart';
import '../../data/models/jellyfin_item.dart';
import '../../domain/jellyfin_track_preferences.dart';
import '../../domain/playback_quality_advisor.dart';
import '../legacy_jellyfin_track_preferences_migration_card.dart';
import '../../providers/jellyfin_providers.dart';
import '../../../playback_quality/data/core_playback_quality_controller.dart';
import '../../../playback_quality/data/core_playback_quality_request_adapter.dart';
import '../../../playback_quality/domain/core_playback_quality_advice.dart';
import '../../../playback_quality/providers/playback_quality_providers.dart';
import '../../../../server/media_segments/data/server_media_segment_controller.dart';
import '../../../../server/media_segments/domain/server_media_segment_models.dart';
import '../../../../server/watch_parties/data/server_watch_party_controller.dart';
import '../../../../server/watch_parties/domain/server_watch_party_models.dart';
import '../../../../server/offline_media/data/server_offline_media_controller.dart';
import '../../../../server/providers/server_providers.dart';
import '../../../../../shared/theme/typography.dart';
import '../../../../../shared/utils/foreground_poller.dart';
import 'playback_reporter.dart';
import '../../../local_audio/providers/local_audio_providers.dart';

final jellyfinPlayerFactoryProvider = Provider<Player Function()>(
  (ref) => Player.new,
);

/// Keeps native rendering separate from command/session tests; the controller
/// stays lazy and is constructed only once by the owning route.
final jellyfinVideoSurfaceProvider =
    Provider<Widget Function(VideoController Function())>(
      (ref) =>
          (controller) => Video(controller: controller(), controls: null),
    );

/// A manual "quality" ceiling — mirrors the bitrate ladder real Jellyfin
/// clients offer. `null` means no cap: Direct Play whenever the declared
/// [buildJellyfinDeviceProfile] allows it, exactly as before this existed.
class _QualityOption {
  const _QualityOption(this.maxBitrate);

  /// Bits per second, or null for "Auto (Original)".
  final int? maxBitrate;
}

const _qualityOptions = [
  _QualityOption(null),
  _QualityOption(120000000),
  _QualityOption(80000000),
  _QualityOption(40000000),
  _QualityOption(20000000),
  _QualityOption(10000000),
  _QualityOption(4000000),
  _QualityOption(1500000),
];

enum _HudKind { brightness, volume }

/// Full-screen playback: negotiates a Jellyfin `PlaybackInfo` source (Direct
/// Play whenever our declared `DeviceProfile` allows it), plays it through
/// `media_kit` (hardware-accelerated via libmpv), and reports start/progress
/// (every 10s)/stop back to Jellyfin so resume/continue-watching works.
///
/// Controls are fully custom (Cupertino, not media_kit's default Material
/// overlay): a tap-to-toggle bottom bar with seek/play/pause, subtitle/
/// audio/quality pickers, and iOS-style edge-swipe gestures — left half of
/// the screen for brightness, right half for volume, double-tap either
/// side to seek ±10s.
class JellyfinPlayerScreen extends ConsumerStatefulWidget {
  const JellyfinPlayerScreen({super.key, required this.item});

  final JellyfinItem item;

  @override
  ConsumerState<JellyfinPlayerScreen> createState() =>
      _JellyfinPlayerScreenState();
}

class _JellyfinPlayerScreenState extends ConsumerState<JellyfinPlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _controller = VideoController(_player);
  late final CorePlaybackQualityController _coreQuality;
  late final ServerMediaSegmentController _mediaSegments;
  late final ServerWatchPartyController _watchParty;
  late final ServerOfflineMediaController _offlineMedia;

  JellyfinClient? _client;
  LegacyJellyfinTrackPreferencesMigrationController? _legacyMigration;
  PlaybackReporter? _reporter;
  late final ForegroundPoller _progressPoller;
  bool _opening = false;
  int _generation = 0;
  bool _foreground = true;
  AppInteractionController? _interaction;
  int? _scopeEpoch;
  int _interactionGeneration = 0;
  bool _scopeInitialized = false;
  bool _pickerBusy = false;
  Route<dynamic>? _pickerRoute;
  int? _dragInteraction;
  int? _seekInteraction;
  Duration? _seekDraft;
  Timer? _watchPartyTimer;
  int _watchPartyRoundTripMs = 0;
  bool _applyingWatchPartyDirective = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (!identical(next, _interaction)) {
      _interaction?.removeListener(_scopeChanged);
      if (_scopeInitialized) _expireInteraction();
      _interaction = next;
      _scopeEpoch = next?.epoch;
      next?.addListener(_scopeChanged);
    }
    _scopeInitialized = true;
  }

  void _scopeChanged() {
    if (!mounted || _scopeEpoch == _interaction?.epoch) return;
    _scopeEpoch = _interaction?.epoch;
    _expireInteraction();
  }

  void _closePicker() {
    final route = _pickerRoute;
    _pickerRoute = null;
    void close() {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => close());
    } else {
      close();
    }
  }

  void _expireInteraction() {
    _interactionGeneration++;
    _legacyMigration?.retire();
    _dragInteraction = null;
    _seekInteraction = null;
    _seekDraft = null;
    _draggingBrightness = false;
    _draggingVolume = false;
    _hideControlsTimer?.cancel();
    _hudTimer?.cancel();
    _hudKind = null;
    _controlsVisible = true;
    _preferenceSaveFailed = false;
    _closePicker();
    void redraw() {
      if (mounted) setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => redraw());
    } else {
      redraw();
    }
  }

  bool _interactionCurrent(int generation, {Route<dynamic>? picker}) =>
      mounted &&
      _foreground &&
      generation == _interactionGeneration &&
      identical(_interaction, AppInteractionScope.maybeRead(context)) &&
      _scopeEpoch == _interaction?.epoch &&
      _interaction?.active != false &&
      (picker == null
          ? TickerMode.valuesOf(context).enabled &&
                ModalRoute.of(context)?.isCurrent != false
          : identical(_pickerRoute, picker) && picker.isCurrent);

  VoidCallback _interactionAction(VoidCallback action) {
    final generation = _interactionGeneration;
    return () {
      if (_interactionCurrent(generation)) action();
    };
  }

  ValueChanged<V> _interactionValueAction<V>(ValueChanged<V> action) {
    final generation = _interactionGeneration;
    return (value) {
      if (_interactionCurrent(generation)) action(value);
    };
  }

  @override
  void didUpdateWidget(covariant JellyfinPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _generation++;
      _expireInteraction();
      _progressPoller.stop();
      unawaited(_reporter?.stop(_position));
      _reporter = null;
      _mediaSegments.retire();
      _watchParty.retire();
      _offlineMedia.retire();
      _ignoreFailure(_player.stop);
      _error = AppLocalizations.of(context).jellyfinPlayerNotConnected;
      _loading = false;
    }
  }

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<Track>? _trackSub;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = true;
  Tracks _tracks = const Tracks();
  Track _currentTrack = const Track();
  int? _selectedMaxBitrate;
  JellyfinTrackPreferenceRecord? _preferredTracks;
  int _sourceEpoch = 0;
  int _preferredAudioEpoch = -1;
  int _preferredSubtitleEpoch = -1;
  bool _preferenceSaveFailed = false;
  PlaybackQualityEvidence? _qualityEvidence;
  CorePlaybackQualityRequest? _coreQualityRequest;

  bool _loading = true;
  String? _error;

  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  _HudKind? _hudKind;
  double _hudValue = 0;
  Timer? _hudTimer;

  bool _draggingBrightness = false;
  bool _draggingVolume = false;
  double _dragStartValue = 0;
  double _dragStartY = 0;

  @override
  void initState() {
    super.initState();
    _player = ref.read(jellyfinPlayerFactoryProvider)();
    _coreQuality = CorePlaybackQualityController(
      ref.read(serverAccountControllerProvider),
    )..addListener(_qualityAdviceChanged);
    _mediaSegments = ServerMediaSegmentController(
      ref.read(serverAccountControllerProvider),
    )..addListener(_mediaSegmentsChanged);
    _watchParty = ServerWatchPartyController(
      ref.read(serverAccountControllerProvider),
    )..addListener(_watchPartyChanged);
    _offlineMedia = ServerOfflineMediaController(
      ref.read(serverAccountControllerProvider),
    )..addListener(_offlineMediaChanged);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _progressPoller = ForegroundPoller(
      interval: const Duration(seconds: 10),
      poll: _reportProgress,
    );
    ref.listenManual(jellyfinClientProvider, (previous, next) {
      if (identical(previous, next) || _client == null) return;
      // Never continue a session with credentials from a previous account.
      _generation++;
      _legacyMigration?.retire();
      _expireInteraction();
      _progressPoller.stop();
      unawaited(_reporter?.stop(_position));
      _reporter = null;
      _mediaSegments.retire();
      _watchParty.retire();
      _offlineMedia.retire();
      _ignoreFailure(_player.stop);
      if (mounted) {
        setState(() {
          _error = AppLocalizations.of(context).jellyfinPlayerNotConnected;
          _loading = false;
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
    _scheduleHideControls();
  }

  void _qualityAdviceChanged() {
    if (mounted) setState(() {});
  }

  void _mediaSegmentsChanged() {
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

  void _offlineMediaChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _expireInteraction();
      _hideControlsTimer?.cancel();
      _hudTimer?.cancel();
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        _ignoreFailure(_player.pause);
      }
    } else {
      if (mounted) setState(() => _controlsVisible = true);
      _scheduleHideControls();
    }
  }

  Future<void> _ignoreFailure(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      /* Best-effort player command. */
    }
  }

  Future<void> _start() async {
    final client = ref.read(jellyfinClientProvider);
    if (client == null) {
      setState(() {
        _error = AppLocalizations.of(context).jellyfinPlayerNotConnected;
        _loading = false;
      });
      return;
    }
    _client = client;
    final generation = _generation;
    _startLegacyMigration(client, generation);

    try {
      await ref.read(localAudioBridgeProvider).stopForVideo();
      if (!mounted ||
          generation != _generation ||
          !identical(ref.read(jellyfinClientProvider), client)) {
        return;
      }
      await _openSource(startPosition: widget.item.resumePosition);
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = AppLocalizations.of(context).mediaReadFailedTitle;
          _loading = false;
        });
      }
    }
  }

  void _startLegacyMigration(JellyfinClient client, int generation) {
    _legacyMigration?.dispose();
    _legacyMigration = null;
    final account = ref.read(serverAccountControllerProvider);
    final session = account.session;
    if (session == null) return;
    final interaction = _interactionGeneration;
    final controller = LegacyJellyfinTrackPreferencesMigrationController(
      migration: LegacyJellyfinTrackPreferencesMigration(
        core: ref.read(jellyfinTrackPreferencesStoreProvider),
      ),
      config: client.config,
      lifecycle: account,
      isCurrent: () =>
          mounted &&
          generation == _generation &&
          _interactionCurrent(interaction) &&
          identical(_client, client) &&
          identical(ref.read(jellyfinClientProvider), client) &&
          identical(account.session, session),
    );
    _legacyMigration = controller;
    unawaited(controller.start());
  }

  Future<bool> _openSource({
    required Duration startPosition,
    int? maxBitrate,
    int? interaction,
  }) async {
    if (_opening) return false;
    _opening = true;
    final generation = _generation;
    final client = _client!;
    bool current() =>
        mounted &&
        generation == _generation &&
        identical(ref.read(jellyfinClientProvider), client) &&
        (interaction == null || _interactionCurrent(interaction));
    try {
      if (!current()) return false;
      await _offlineMedia.closePlayback();
      if (!current()) return false;
      final source = await client.getPlaybackInfo(
        widget.item.id,
        maxStreamingBitrate: interaction == null
            ? _selectedMaxBitrate
            : maxBitrate,
      );
      if (!current()) return false;
      _progressPoller.stop();
      await _reporter?.stop(_position);
      _reporter = null;
      if (!current()) return false;
      // Old track IDs cannot authorize selection in a replacement source.
      _tracksSub?.cancel();
      _tracksSub = null;
      _trackSub?.cancel();
      _trackSub = null;
      _coreQuality.retire();
      _mediaSegments.retire();
      setState(() {
        _sourceEpoch++;
        _position = startPosition;
        _duration = Duration.zero;
        _seekDraft = null;
        _preferredTracks = null;
        _qualityEvidence = source.qualityEvidence;
        _coreQualityRequest = null;
        _tracks = const Tracks();
        _currentTrack = const Track();
      });
      final sourceEpoch = _sourceEpoch;
      final qualityInteraction = _interactionGeneration;
      unawaited(
        _loadCoreQualityAdvice(
          source,
          sourceEpoch: sourceEpoch,
          interaction: qualityInteraction,
          client: client,
        ),
      );
      await _player.open(Media(source.streamUrl), play: _foreground);
      if (!mounted) return false;
      if (generation != _generation) {
        await _ignoreFailure(_player.stop);
        return false;
      }
      if (!current()) return false;
      if (startPosition > Duration.zero) {
        await _player.seek(startPosition);
        if (!current()) return false;
      }
      try {
        _preferredTracks = await ref
            .read(jellyfinTrackPreferencesStoreProvider)
            .read(client.config, isCurrent: current);
      } catch (_) {
        // A missing or untrusted local preference must never prevent playback.
        _preferredTracks = null;
      }
      if (!current()) return false;
      final reporter = PlaybackReporter(
        client: client,
        itemId: widget.item.id,
        source: source,
      );
      _reporter = reporter;
      await reporter.start(startPosition);
      if (!current()) return false;
      unawaited(
        _loadMediaSegments(
          itemId: widget.item.id,
          itemEpoch: generation,
          sourceEpoch: sourceEpoch,
          client: client,
          reporter: reporter,
        ),
      );

      _positionSub?.cancel();
      _positionSub = _player.stream.position.listen((position) {
        final changedSecond = position.inSeconds != _position.inSeconds;
        _position = position;
        if (mounted && changedSecond) setState(() {});
      });
      _durationSub?.cancel();
      _durationSub = _player.stream.duration.listen((duration) {
        if (mounted) setState(() => _duration = duration);
      });
      _playingSub?.cancel();
      _playingSub = _player.stream.playing.listen((playing) {
        if (mounted) setState(() => _playing = playing);
      });
      _tracksSub = _player.stream.tracks.listen((tracks) {
        if (!mounted) return;
        setState(() => _tracks = tracks);
        unawaited(_applyPreferredTracks(tracks, sourceEpoch, client));
      });
      _trackSub = _player.stream.track.listen((track) {
        if (mounted) setState(() => _currentTrack = track);
      });

      _progressPoller.start(immediately: false);
      return true;
    } finally {
      _opening = false;
    }
  }

  Future<void> _loadMediaSegments({
    required String itemId,
    required int itemEpoch,
    required int sourceEpoch,
    required JellyfinClient client,
    required PlaybackReporter reporter,
  }) => _mediaSegments.loadCurrentItem(
    itemId,
    sourceEpoch: sourceEpoch,
    itemEpoch: itemEpoch,
    current: () =>
        mounted &&
        _foreground &&
        widget.item.id == itemId &&
        itemEpoch == _generation &&
        sourceEpoch == _sourceEpoch &&
        identical(_client, client) &&
        identical(ref.read(jellyfinClientProvider), client) &&
        identical(_reporter, reporter),
  );

  ServerMediaSegment? get _activeMediaSegment {
    final result = _mediaSegments.result;
    if (result == null ||
        !result.isCurrent(sourceEpoch: _sourceEpoch, itemEpoch: _generation) ||
        _duration <= Duration.zero) {
      return null;
    }
    final segment = result.segmentAt(_position);
    if (segment == null || segment.end > _duration) return null;
    return segment;
  }

  Future<void> _skipMediaSegment(ServerMediaSegment expected) async {
    final current = _activeMediaSegment;
    if (current == null ||
        current.kind != expected.kind ||
        current.start != expected.start ||
        current.end != expected.end) {
      return;
    }
    await _seekAndBroadcast(current.end);
  }

  bool get _watchPartyRouteCurrent =>
      mounted &&
      _foreground &&
      !_opening &&
      !_loading &&
      _error == null &&
      _client != null &&
      _reporter != null;

  bool get _offlineMediaRouteCurrent =>
      mounted && _foreground && !_loading && _error == null && _client != null;

  Future<void> _playOfflineMedia() async {
    if (_opening) return;
    _opening = true;
    final generation = _generation;
    bool current() => _offlineMediaRouteCurrent && generation == _generation;
    try {
      final uri = await _offlineMedia.openPlayback(current: current);
      if (uri == null || !current()) return;
      _progressPoller.stop();
      await _reporter?.stop(_position);
      _reporter = null;
      if (!current()) return;
      _coreQuality.retire();
      _mediaSegments.retire();
      _watchParty.retire();
      setState(() {
        _sourceEpoch++;
        _position = Duration.zero;
        _duration = Duration.zero;
        _seekDraft = null;
        _qualityEvidence = null;
        _coreQualityRequest = null;
      });
      await _player.open(Media(uri.toString()), play: _foreground);
      if (!current()) await _ignoreFailure(_player.stop);
    } catch (_) {
      await _offlineMedia.closePlayback();
      if (mounted && generation == _generation) {
        setState(
          () => _error = AppLocalizations.of(context).mediaReadFailedTitle,
        );
      }
    } finally {
      _opening = false;
    }
  }

  Future<void> _showOfflineMediaSheet() async {
    final l10n = AppLocalizations.of(context);
    final manifest = _offlineMedia.manifest;
    final progress = manifest == null
        ? 0
        : ((manifest.downloadedBytes * 100) ~/ manifest.contentLength).clamp(
            0,
            100,
          );
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.jellyfinOfflineMediaTitle),
        message: Text(
          manifest == null
              ? l10n.jellyfinOfflineMediaHint
              : manifest.complete
              ? l10n.jellyfinOfflineMediaReady
              : l10n.jellyfinOfflineMediaProgress(progress),
        ),
        actions: [
          if (manifest?.complete == true && !_offlineMedia.busy)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                unawaited(_playOfflineMedia());
              },
              child: Text(l10n.jellyfinOfflineMediaPlay),
            ),
          if ((manifest == null || !manifest.complete) && !_offlineMedia.busy)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  _offlineMedia.downloadCurrentItem(
                    widget.item.id,
                    current: () => _offlineMediaRouteCurrent,
                  ),
                );
              },
              child: Text(
                manifest == null
                    ? l10n.jellyfinOfflineMediaDownload
                    : l10n.jellyfinOfflineMediaResume,
              ),
            ),
          if (manifest != null)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  _offlineMedia.cancel(
                    current: () => _offlineMediaRouteCurrent,
                  ),
                );
              },
              child: Text(l10n.jellyfinOfflineMediaRemove),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
  }

  bool get _watchPartyLeader {
    final snapshot = _watchParty.snapshot;
    final account = ref.read(serverAccountControllerProvider).session?.user.id;
    return snapshot != null && account == snapshot.leaderAccountId;
  }

  Future<void> _watchPartyTick() async {
    final snapshot = _watchParty.snapshot;
    final family = ref
        .read(serverAccountControllerProvider)
        .session
        ?.sessionFamilyId;
    if (snapshot == null ||
        family == null ||
        _watchParty.busy ||
        !_watchPartyRouteCurrent) {
      return;
    }
    if (_watchParty.failure == 'watch_party_authority_changed') {
      await _watchParty.refresh(current: () => _watchPartyRouteCurrent);
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
        state: _opening
            ? ServerWatchPartyPlaybackState.buffering
            : _playing
            ? ServerWatchPartyPlaybackState.playing
            : ServerWatchPartyPlaybackState.paused,
        positionMs: _position.inMilliseconds,
        measuredRoundTripMs: _watchPartyRoundTripMs,
      ),
      current: () => _watchPartyRouteCurrent,
    );
    stopwatch.stop();
    _watchPartyRoundTripMs = stopwatch.elapsedMilliseconds.clamp(0, 10000);
    await _applyWatchPartyDirective();
  }

  Future<void> _applyWatchPartyDirective() async {
    final directive = _watchParty.snapshot?.directive;
    if (directive == null ||
        directive.action == ServerWatchPartyDirectiveAction.none ||
        directive.action == ServerWatchPartyDirectiveAction.unsupported ||
        _applyingWatchPartyDirective ||
        !_watchPartyRouteCurrent) {
      return;
    }
    _applyingWatchPartyDirective = true;
    try {
      switch (directive.action) {
        case ServerWatchPartyDirectiveAction.pause:
          await _ignoreFailure(_player.pause);
          break;
        case ServerWatchPartyDirectiveAction.play:
        case ServerWatchPartyDirectiveAction.seekAndPlay:
          await _ignoreFailure(
            () => _player.seek(Duration(milliseconds: directive.positionMs)),
          );
          if (_watchPartyRouteCurrent) await _ignoreFailure(_player.play);
        case ServerWatchPartyDirectiveAction.none:
        case ServerWatchPartyDirectiveAction.unsupported:
          break;
      }
    } finally {
      _applyingWatchPartyDirective = false;
    }
  }

  Future<void> _broadcastWatchPartyCommand(
    String action,
    Duration position,
  ) async {
    if (!_watchPartyLeader || !_watchPartyRouteCurrent) return;
    await _watchParty.command(
      action: action,
      position: position,
      current: () => _watchPartyRouteCurrent,
    );
  }

  Future<void> _seekAndBroadcast(Duration position) async {
    await _ignoreFailure(() => _player.seek(position));
    await _broadcastWatchPartyCommand(_playing ? 'seek' : 'pause', position);
  }

  Future<void> _createWatchParty() async {
    await _watchParty.createCurrentItem(
      widget.item.id,
      current: () => _watchPartyRouteCurrent,
    );
    final value = _watchParty.invitation?.value;
    if (value != null) {
      await Clipboard.setData(ClipboardData(text: value));
    }
  }

  Future<void> _joinWatchParty() async {
    final controller = TextEditingController();
    final value = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(AppLocalizations.of(context).jellyfinWatchPartyJoin),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
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
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(AppLocalizations.of(context).jellyfinWatchPartyJoin),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty || !_watchPartyRouteCurrent) {
      return;
    }
    await _watchParty.join(
      value,
      itemId: widget.item.id,
      current: () => _watchPartyRouteCurrent,
    );
  }

  Future<void> _showWatchPartySheet() async {
    final snapshot = _watchParty.snapshot;
    final l10n = AppLocalizations.of(context);
    final failure = _watchParty.failure;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.jellyfinWatchPartyTitle),
        message: snapshot == null
            ? Text(l10n.jellyfinWatchPartyHint)
            : Text(
                '${l10n.jellyfinWatchPartyStatus(snapshot.participants.where((item) => item.connected).length, snapshot.toleranceMs)}${failure == null ? '' : '\n${l10n.jellyfinWatchPartyRefreshNeeded}'}',
              ),
        actions: snapshot == null
            ? [
                CupertinoActionSheetAction(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_createWatchParty());
                  },
                  child: Text(l10n.jellyfinWatchPartyCreate),
                ),
                CupertinoActionSheetAction(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_joinWatchParty());
                  },
                  child: Text(l10n.jellyfinWatchPartyJoin),
                ),
              ]
            : [
                if (_watchPartyLeader)
                  for (final member in snapshot.participants.where(
                    (item) => !item.isLeader && item.connected,
                  ))
                    CupertinoActionSheetAction(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          _watchParty.transfer(
                            nextLeader: member,
                            current: () => _watchPartyRouteCurrent,
                          ),
                        );
                      },
                      child: Text(
                        l10n.jellyfinWatchPartyTransfer(
                          member.accountId.substring(26),
                        ),
                      ),
                    ),
                if (_watchParty.invitation != null)
                  CupertinoActionSheetAction(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _watchParty.invitation!.value),
                      );
                      Navigator.of(sheetContext).pop();
                    },
                    child: Text(l10n.jellyfinWatchPartyCopyCode),
                  ),
                CupertinoActionSheetAction(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(
                      _watchParty.refresh(
                        current: () => _watchPartyRouteCurrent,
                      ),
                    );
                  },
                  child: Text(l10n.commonRefresh),
                ),
                CupertinoActionSheetAction(
                  isDestructiveAction: true,
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(
                      _watchParty.leave(current: () => _watchPartyRouteCurrent),
                    );
                  },
                  child: Text(l10n.jellyfinWatchPartyLeave),
                ),
              ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
  }

  Future<void> _loadCoreQualityAdvice(
    JellyfinPlaybackSource source, {
    required int sourceEpoch,
    required int interaction,
    required JellyfinClient client,
  }) async {
    bool current() =>
        sourceEpoch == _sourceEpoch &&
        identical(_client, client) &&
        identical(ref.read(jellyfinClientProvider), client) &&
        _interactionCurrent(interaction);
    try {
      final snapshot = await ref
          .read(androidPlaybackCapabilityPortProvider)
          .snapshot();
      if (!current()) return;
      final request = CorePlaybackQualityRequestAdapter.localAndroid(
        source,
        snapshot,
      );
      setState(() => _coreQualityRequest = request);
      await _coreQuality.advise(request, current: current);
    } catch (_) {
      if (!current()) return;
      final request = CorePlaybackQualityRequestAdapter.localAndroid(
        source,
        null,
      );
      setState(() => _coreQualityRequest = request);
      await _coreQuality.advise(request, current: current);
    }
  }

  Future<void> _applyPreferredTracks(
    Tracks tracks,
    int sourceEpoch,
    JellyfinClient client,
  ) async {
    final interactionGeneration = _interactionGeneration;
    bool current() =>
        sourceEpoch == _sourceEpoch &&
        identical(_client, client) &&
        _interactionCurrent(interactionGeneration) &&
        identical(ref.read(jellyfinClientProvider), client) &&
        !_pickerBusy;
    if (!current()) return;
    final preferred = _preferredTracks;
    if (preferred == null) return;
    if (_preferredAudioEpoch != sourceEpoch) {
      final audio = JellyfinTrackPreferences.audio(
        tracks.audio,
        preferred.audioLanguage,
      );
      if (audio != null &&
          _tracks.audio.any((available) => identical(available, audio)) &&
          current()) {
        _preferredAudioEpoch = sourceEpoch;
        try {
          await _player.setAudioTrack(audio);
        } catch (_) {
          // The player rejected this choice; do not claim it was selected.
        }
      }
    }
    if (!current() || _preferredSubtitleEpoch == sourceEpoch) return;
    final subtitle = JellyfinTrackPreferences.subtitle(
      tracks.subtitle,
      preferred.subtitleLanguage,
    );
    if (subtitle != null &&
        (subtitle.id == 'no' ||
            _tracks.subtitle.any(
              (available) => identical(available, subtitle),
            )) &&
        current()) {
      _preferredSubtitleEpoch = sourceEpoch;
      try {
        await _player.setSubtitleTrack(subtitle);
      } catch (_) {
        // The active media source remains authoritative.
      }
    }
  }

  Future<void> _selectPreferredAudio(AudioTrack track, int generation) async {
    final client = _client;
    final sourceEpoch = _sourceEpoch;
    if (client == null || !_interactionCurrent(generation)) return;
    try {
      await _player.setAudioTrack(track);
    } catch (_) {
      return;
    }
    if (!_preferenceWriteCurrent(client, sourceEpoch, generation) ||
        !_tracks.audio.any((available) => identical(available, track))) {
      return;
    }
    final String? language;
    try {
      language = JellyfinTrackPreferences.normalize(track.language);
    } on FormatException {
      return;
    }
    if (language == null) return;
    setState(() => _preferenceSaveFailed = false);
    try {
      final saved = await ref
          .read(jellyfinTrackPreferencesStoreProvider)
          .saveAudio(
            client.config,
            language: language,
            isCurrent: () =>
                _preferenceWriteCurrent(client, sourceEpoch, generation),
          );
      if (_preferenceWriteCurrent(client, sourceEpoch, generation)) {
        setState(() => _preferenceSaveFailed = false);
        _preferredTracks = saved;
        _preferredAudioEpoch = sourceEpoch;
      }
    } catch (_) {
      if (_preferenceWriteCurrent(client, sourceEpoch, generation)) {
        setState(() => _preferenceSaveFailed = true);
      }
    }
  }

  Future<void> _selectPreferredSubtitle(
    SubtitleTrack track,
    int generation,
  ) async {
    final client = _client;
    final sourceEpoch = _sourceEpoch;
    if (client == null || !_interactionCurrent(generation)) return;
    try {
      await _player.setSubtitleTrack(track);
    } catch (_) {
      return;
    }
    if (!_preferenceWriteCurrent(client, sourceEpoch, generation) ||
        (track.id != 'no' &&
            !_tracks.subtitle.any(
              (available) => identical(available, track),
            ))) {
      return;
    }
    final String? language;
    try {
      language = track.id == 'no'
          ? 'off'
          : JellyfinTrackPreferences.normalize(track.language, allowOff: true);
    } on FormatException {
      return;
    }
    if (language == null) return;
    setState(() => _preferenceSaveFailed = false);
    try {
      final saved = await ref
          .read(jellyfinTrackPreferencesStoreProvider)
          .saveSubtitle(
            client.config,
            language: language,
            isCurrent: () =>
                _preferenceWriteCurrent(client, sourceEpoch, generation),
          );
      if (_preferenceWriteCurrent(client, sourceEpoch, generation)) {
        setState(() => _preferenceSaveFailed = false);
        _preferredTracks = saved;
        _preferredSubtitleEpoch = sourceEpoch;
      }
    } catch (_) {
      if (_preferenceWriteCurrent(client, sourceEpoch, generation)) {
        setState(() => _preferenceSaveFailed = true);
      }
    }
  }

  bool _preferenceWriteCurrent(
    JellyfinClient client,
    int sourceEpoch,
    int generation,
  ) =>
      sourceEpoch == _sourceEpoch &&
      _interactionCurrent(generation) &&
      identical(ref.read(jellyfinClientProvider), client);

  Future<void> _reportProgress() async {
    await _reporter?.progress(_position, isPaused: !_player.state.playing);
  }

  Future<void> _changeQuality(int? maxBitrate, int interaction) async {
    if (!_interactionCurrent(interaction) ||
        _opening ||
        maxBitrate == _selectedMaxBitrate) {
      return;
    }
    final resumeAt = _position;
    final wasPlaying = _playing;
    try {
      final opened = await _openSource(
        startPosition: resumeAt,
        maxBitrate: maxBitrate,
        interaction: interaction,
      );
      if (!opened || !_interactionCurrent(interaction)) return;
      setState(() => _selectedMaxBitrate = maxBitrate);
      if (!wasPlaying) await _player.pause();
    } catch (_) {
      if (_interactionCurrent(interaction)) {
        await _ignoreFailure(_player.pause);
        if (!_interactionCurrent(interaction)) return;
        setState(() {
          _error = AppLocalizations.of(context)
              .jellyfinPlayerQualityChangeFailed;
        });
      }
    }
  }

  Future<void> _togglePlaying() async {
    final action = _playing ? 'pause' : 'play';
    await _ignoreFailure(_player.playOrPause);
    await _broadcastWatchPartyCommand(action, _position);
    _scheduleHideControls();
  }

  void _seekBy(Duration delta) {
    final target = _position + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    unawaited(_seekAndBroadcast(clamped));
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    if (!mounted || !_foreground) return;
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    final width = MediaQuery.of(context).size.width;
    final dx = details.localPosition.dx;
    if (dx < width / 3) {
      _seekBy(const Duration(seconds: -10));
    } else if (dx > width * 2 / 3) {
      _seekBy(const Duration(seconds: 10));
    }
  }

  Future<void> _handleVerticalDragStart(DragStartDetails details) async {
    final generation = _interactionGeneration;
    if (!_interactionCurrent(generation)) return;
    _dragInteraction = generation;
    final width = MediaQuery.of(context).size.width;
    _dragStartY = details.globalPosition.dy;
    if (details.globalPosition.dx < width / 2) {
      _draggingBrightness = true;
      try {
        final value = await ScreenBrightness().application;
        if (_interactionCurrent(generation) && _dragInteraction == generation) {
          _dragStartValue = value;
        }
      } catch (_) {
        if (_interactionCurrent(generation) && _dragInteraction == generation) {
          _dragStartValue = 0.5;
        }
      }
    } else {
      _draggingVolume = true;
      _dragStartValue = _player.state.volume / 100;
    }
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_dragInteraction != _interactionGeneration ||
        !_interactionCurrent(_interactionGeneration) ||
        (!_draggingBrightness && !_draggingVolume)) {
      return;
    }
    final height = MediaQuery.of(context).size.height;
    final delta = (_dragStartY - details.globalPosition.dy) / height;
    final value = (_dragStartValue + delta).clamp(0.0, 1.0);

    if (_draggingBrightness) {
      ScreenBrightness()
          .setApplicationScreenBrightness(value)
          .catchError((_) {});
      _showHud(_HudKind.brightness, value);
    } else {
      _ignoreFailure(() => _player.setVolume(value * 100));
      _showHud(_HudKind.volume, value);
    }
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    _dragInteraction = null;
    _draggingBrightness = false;
    _draggingVolume = false;
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _hudKind = null);
    });
  }

  void _showHud(_HudKind kind, double value) {
    _hudTimer?.cancel();
    setState(() {
      _hudKind = kind;
      _hudValue = value;
    });
  }

  Future<void> _pick<R>({
    required String title,
    String? message,
    required List<R> options,
    required Widget Function(R) label,
    required bool Function(R) available,
    required Future<void> Function(R, int) apply,
  }) async {
    final generation = _interactionGeneration;
    if (_pickerBusy ||
        _opening ||
        _loading ||
        _error != null ||
        _client == null ||
        !_interactionCurrent(generation)) {
      return;
    }
    _pickerBusy = true;
    _hideControlsTimer?.cancel();
    late final CupertinoModalPopupRoute<R> route;
    void choose([R? selected]) {
      if (!_interactionCurrent(generation, picker: route)) return;
      route.navigator?.pop(selected);
    }

    route = CupertinoModalPopupRoute<R>(
      builder: (_) => CupertinoActionSheet(
        title: Text(title),
        message: message == null ? null : Text(message),
        actions: [
          for (final option in options)
            CupertinoActionSheetAction(
              onPressed: () => choose(option),
              child: label(option),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: choose,
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    _pickerRoute = route;
    try {
      final selected = await Navigator.of(
        context,
        rootNavigator: true,
      ).push<R>(route);
      await route.completed;
      if (selected != null &&
          _interactionCurrent(generation) &&
          available(selected)) {
        await apply(selected, generation);
      }
    } finally {
      if (identical(_pickerRoute, route)) _pickerRoute = null;
      _pickerBusy = false;
      if (_interactionCurrent(generation)) _scheduleHideControls();
    }
  }

  String get _languagePreferenceHint =>
      Localizations.localeOf(context).languageCode == 'tr'
      ? 'Dil etiketi olan bir parça seçmek bu Larenor hesabı için dilini kaydeder. Sonraki içerikte yoksa oynatıcı mevcut bir parçayı kullanır.'
      : 'Choosing a track with a language label saves that language for this Larenor account. If a later title lacks it, playback keeps an available track.';

  String get _languagePreferenceFallback =>
      Localizations.localeOf(context).languageCode == 'tr'
      ? 'Parça yalnızca bu video için değişti. Core dil tercihin kaydedilemedi.'
      : 'The track changed for this video only. Your Core language preference could not be saved.';

  Future<void> _showSubtitlePicker() {
    final l10n = AppLocalizations.of(context);
    return _pick<SubtitleTrack>(
      title: l10n.jellyfinPlayerSubtitlesTitle,
      message: _languagePreferenceHint,
      options: [
        SubtitleTrack.no(),
        ..._tracks.subtitle.where((track) => track.id != 'no'),
      ],
      label: (track) => Text(
        _trackLabel(track, l10n, isOff: track.id == 'no'),
        style: track.id == _currentTrack.subtitle.id
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      ),
      available: (track) =>
          track.id == 'no' ||
          _tracks.subtitle.any((current) => identical(current, track)),
      apply: _selectPreferredSubtitle,
    );
  }

  Future<void> _showAudioPicker() {
    final l10n = AppLocalizations.of(context);
    if (_tracks.audio.isEmpty) return Future.value();
    return _pick<AudioTrack>(
      title: l10n.jellyfinPlayerAudioTitle,
      message: _languagePreferenceHint,
      options: List.of(_tracks.audio),
      label: (track) => Text(
        _trackLabel(track, l10n, isOff: false),
        style: track.id == _currentTrack.audio.id
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      ),
      available: (track) =>
          _tracks.audio.any((current) => identical(current, track)),
      apply: _selectPreferredAudio,
    );
  }

  Future<void> _showQualityPicker() {
    final l10n = AppLocalizations.of(context);
    return _pick<_QualityOption>(
      title: l10n.jellyfinPlayerQualityTitle,
      message: _qualityAdvisorMessage(l10n),
      options: _qualityOptions,
      label: (option) => Text(
        option.maxBitrate == null
            ? l10n.jellyfinPlayerQualityAuto
            : '${(option.maxBitrate! / 1000000).round()} Mbps',
        style: option.maxBitrate == _selectedMaxBitrate
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      ),
      available: _qualityOptions.contains,
      apply: (option, generation) =>
          _changeQuality(option.maxBitrate, generation),
    );
  }

  String _qualityAdvisorMessage(AppLocalizations l10n) {
    final evidence = _qualityEvidence;
    if (evidence == null) return l10n.jellyfinQualityAdvisorUnavailable;
    final advice = _coreQuality.advice;
    final method = switch (advice?.method) {
      CorePlaybackMethod.directPlay => l10n.jellyfinQualityAdvisorDirectPlay,
      CorePlaybackMethod.remux => l10n.jellyfinQualityAdvisorRemux,
      CorePlaybackMethod.transcode => l10n.jellyfinQualityAdvisorTranscode,
      CorePlaybackMethod.unknown => l10n.jellyfinQualityAdvisorUnavailable,
      null => switch (evidence.method) {
        PlaybackDeliveryMethod.directPlay =>
          l10n.jellyfinQualityAdvisorDirectPlay,
        PlaybackDeliveryMethod.remux => l10n.jellyfinQualityAdvisorRemux,
        PlaybackDeliveryMethod.transcode =>
          l10n.jellyfinQualityAdvisorTranscode,
      },
    };
    String value(String? input) =>
        input == null ? l10n.commonUnknown : input.toUpperCase();
    String bitrate(int? input) => input == null
        ? l10n.commonUnknown
        : '${(input / 1000000).toStringAsFixed(input >= 10000000 ? 0 : 1)} Mbps';
    final reason = evidence.reasons.isEmpty
        ? l10n.jellyfinQualityAdvisorReasonUnknown
        : evidence.reasons.join(', ');
    final lines = <String>[
      l10n.jellyfinQualityAdvisorPath(method),
      l10n.jellyfinQualityAdvisorEvidence(
        value(evidence.sourceContainer),
        value(evidence.videoCodec),
        value(evidence.audioCodec),
        bitrate(evidence.sourceBitrate),
      ),
      l10n.jellyfinQualityAdvisorReason(reason),
    ];
    final request = _coreQualityRequest;
    final network = request?.network;
    if (network == null || network.state == CorePlaybackEvidenceState.unknown) {
      lines.add(l10n.jellyfinQualityAdvisorNetworkUnknown);
    } else {
      lines.add(
        l10n.jellyfinQualityAdvisorNetworkReported(
          network.transport?.name ?? l10n.commonUnknown,
          network.downstreamKbps?.toString() ?? l10n.commonUnknown,
        ),
      );
    }
    final receiver = request?.receiver;
    if (receiver == null ||
        receiver.state == CorePlaybackEvidenceState.unknown) {
      lines.add(l10n.jellyfinQualityAdvisorReceiver);
    } else {
      final resolution = receiver.maxWidth == null
          ? l10n.commonUnknown
          : '${receiver.maxWidth}×${receiver.maxHeight}';
      lines.add(
        l10n.jellyfinQualityAdvisorReceiverReported(
          receiver.videoCodecs.length,
          receiver.audioCodecs.length,
          resolution,
        ),
      );
    }
    if (advice != null) {
      lines.add(
        l10n.jellyfinQualityAdvisorCoreEvidence(
          _qualityEvidenceState(l10n, advice.codecEvidence),
          _qualityEvidenceState(l10n, advice.bitrateEvidence),
          _qualityEvidenceState(l10n, advice.networkEvidence),
          _qualityEvidenceState(l10n, advice.receiverEvidence),
          _qualityEvidenceState(l10n, advice.hdrEvidence),
        ),
      );
      if (advice.gaps.isNotEmpty) {
        lines.add(
          l10n.jellyfinQualityAdvisorGaps(
            advice.gaps.map((gap) => _qualityGap(l10n, gap)).join(', '),
          ),
        );
      }
      if (advice.recommendations.isNotEmpty) {
        lines.add(
          l10n.jellyfinQualityAdvisorRecommendations(
            advice.recommendations
                .map((item) => _qualityRecommendation(l10n, item.code))
                .join(', '),
          ),
        );
      }
      lines.add(l10n.jellyfinQualityAdvisorManualAcceptance);
    }
    return lines.join('\n');
  }

  String _qualityEvidenceState(
    AppLocalizations l10n,
    CorePlaybackEvidenceState state,
  ) => switch (state) {
    CorePlaybackEvidenceState.reported =>
      l10n.jellyfinQualityAdvisorStateReported,
    CorePlaybackEvidenceState.verified =>
      l10n.jellyfinQualityAdvisorStateVerified,
    CorePlaybackEvidenceState.unknown =>
      l10n.jellyfinQualityAdvisorStateUnknown,
  };

  String _qualityGap(AppLocalizations l10n, String code) => switch (code) {
    'source_telemetry_missing' => l10n.jellyfinQualityAdvisorGapSource,
    'codec_telemetry_missing' => l10n.jellyfinQualityAdvisorGapCodec,
    'bitrate_telemetry_missing' => l10n.jellyfinQualityAdvisorGapBitrate,
    'network_telemetry_missing' => l10n.jellyfinQualityAdvisorGapNetwork,
    'receiver_telemetry_missing' => l10n.jellyfinQualityAdvisorGapReceiver,
    'hdr_telemetry_missing' => l10n.jellyfinQualityAdvisorGapHdr,
    _ => l10n.commonUnknown,
  };

  String _qualityRecommendation(
    AppLocalizations l10n,
    CorePlaybackRecommendationCode code,
  ) => switch (code) {
    CorePlaybackRecommendationCode.keepOriginal =>
      l10n.jellyfinQualityAdvisorKeepOriginal,
    CorePlaybackRecommendationCode.lowerBitrate =>
      l10n.jellyfinQualityAdvisorLowerBitrate,
    CorePlaybackRecommendationCode.preferCompatibleAudio =>
      l10n.jellyfinQualityAdvisorCompatibleAudio,
    CorePlaybackRecommendationCode.preferExternalSubtitle =>
      l10n.jellyfinQualityAdvisorExternalSubtitle,
    CorePlaybackRecommendationCode.inspectReceiver =>
      l10n.jellyfinQualityAdvisorInspectReceiver,
    CorePlaybackRecommendationCode.measureNetwork =>
      l10n.jellyfinQualityAdvisorMeasureNetwork,
    CorePlaybackRecommendationCode.verifyHdrOnDevice =>
      l10n.jellyfinQualityAdvisorVerifyHdr,
  };

  String _trackLabel(
    dynamic track,
    AppLocalizations l10n, {
    required bool isOff,
  }) {
    if (isOff) return l10n.jellyfinPlayerSubtitlesOff;
    final title = track.title as String?;
    final language = track.language as String?;
    if (title != null && title.isNotEmpty) return title;
    if (language != null && language.isNotEmpty) return language;
    final index = int.tryParse(track.id as String) ?? 0;
    return l10n.jellyfinPlayerTrackUnnamed(index);
  }

  @override
  void dispose() {
    _interactionGeneration++;
    _interaction?.removeListener(_scopeChanged);
    _closePicker();
    _hideControlsTimer?.cancel();
    _hudTimer?.cancel();
    _generation++;
    _legacyMigration?.dispose();
    _coreQuality.removeListener(_qualityAdviceChanged);
    _coreQuality.dispose();
    _mediaSegments.removeListener(_mediaSegmentsChanged);
    _mediaSegments.dispose();
    _watchPartyTimer?.cancel();
    _watchParty.removeListener(_watchPartyChanged);
    _watchParty.dispose();
    _offlineMedia.removeListener(_offlineMediaChanged);
    _offlineMedia.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _progressPoller.dispose();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _tracksSub?.cancel();
    _trackSub?.cancel();
    unawaited(_reporter?.stop(_position));
    _ignoreFailure(_player.dispose);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PreventAmbientDisplay(
    active: _playing && !_loading && _error == null,
    child: _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final activeSegment = _activeMediaSegment;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      navigationBar: _loading || _error != null
          ? CupertinoNavigationBar(
              backgroundColor: CupertinoColors.black,
              leading: CupertinoButton(
                key: const ValueKey('jellyfin-player-back'),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(
                  () => Navigator.of(context).maybePop(),
                ),
                child: Icon(
                  CupertinoIcons.chevron_back,
                  color: CupertinoColors.white,
                  semanticLabel: l10n.commonBack,
                ),
              ),
              middle: Text(
                widget.item.name,
                style: const TextStyle(color: CupertinoColors.white),
              ),
            )
          : null,
      child: _loading
          ? const Center(
              child: CupertinoActivityIndicator(color: CupertinoColors.white),
            )
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CupertinoColors.white),
                ),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: ref.watch(jellyfinVideoSurfaceProvider)(
                    () => _controller,
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _interactionAction(_toggleControls),
                    onDoubleTapDown: _interactionValueAction(
                      _handleDoubleTapDown,
                    ),
                    onVerticalDragStart: _interactionValueAction(
                      _handleVerticalDragStart,
                    ),
                    onVerticalDragUpdate: _interactionValueAction(
                      _handleVerticalDragUpdate,
                    ),
                    onVerticalDragEnd: _interactionValueAction(
                      _handleVerticalDragEnd,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                if (_hudKind != null) Center(child: _buildHud()),
                if (_legacyMigration case final migration?)
                  Positioned(
                    top: 72,
                    left: 16,
                    right: 16,
                    child: SafeArea(
                      bottom: false,
                      child: LegacyJellyfinTrackPreferencesMigrationCard(
                        controller: migration,
                      ),
                    ),
                  ),
                if (_preferenceSaveFailed)
                  Positioned(
                    key: const ValueKey(
                      'jellyfin-language-preference-fallback',
                    ),
                    top: 72,
                    left: 16,
                    right: 16,
                    child: SafeArea(
                      bottom: false,
                      child: Semantics(
                        liveRegion: true,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemOrange.darkColor
                                .withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _languagePreferenceFallback,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: CupertinoColors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_controlsVisible) _buildTopBar(l10n),
                if (_controlsVisible) _buildBottomBar(l10n),
                if (activeSegment != null)
                  _buildSkipSegmentButton(activeSegment, l10n),
              ],
            ),
    );
  }

  Widget _buildSkipSegmentButton(
    ServerMediaSegment segment,
    AppLocalizations l10n,
  ) {
    final label = switch (segment.kind) {
      ServerMediaSegmentKind.intro => l10n.jellyfinPlayerSkipIntro,
      ServerMediaSegmentKind.outro => l10n.jellyfinPlayerSkipOutro,
    };
    return Positioned(
      right: 16,
      bottom: _controlsVisible ? 104 : 16,
      child: SafeArea(
        top: false,
        left: false,
        child: Semantics(
          button: true,
          label: label,
          child: CupertinoButton(
            key: ValueKey('jellyfin-player-skip-${segment.kind.name}'),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            color: CupertinoColors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(22),
            onPressed: _interactionAction(
              () => unawaited(_skipMediaSegment(segment)),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHud() {
    final icon = _hudKind == _HudKind.brightness
        ? CupertinoIcons.brightness
        : (_hudValue == 0
              ? CupertinoIcons.volume_off
              : CupertinoIcons.volume_up);
    return IgnorePointer(
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: CupertinoColors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: CupertinoColors.white, size: 32),
            const SizedBox(height: 8),
            Text(
              '${(_hudValue * 100).round()}%',
              style: const TextStyle(color: CupertinoColors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(AppLocalizations l10n) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                CupertinoColors.black.withValues(alpha: 0.7),
                CupertinoColors.black.withValues(alpha: 0),
              ],
            ),
          ),
          child: Row(
            children: [
              CupertinoButton(
                key: const ValueKey('jellyfin-player-back'),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(
                  () => Navigator.of(context).pop(),
                ),
                child: Icon(
                  CupertinoIcons.chevron_back,
                  color: CupertinoColors.white,
                  semanticLabel: l10n.commonBack,
                ),
              ),
              Expanded(
                child: Text(
                  widget.item.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              CupertinoButton(
                key: const ValueKey('jellyfin-player-watch-party'),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(
                  () => unawaited(_showWatchPartySheet()),
                ),
                child: Icon(
                  _watchParty.snapshot == null
                      ? CupertinoIcons.person_2
                      : CupertinoIcons.person_2_fill,
                  color: CupertinoColors.white,
                  semanticLabel: l10n.jellyfinWatchPartyTitle,
                ),
              ),
              CupertinoButton(
                key: const ValueKey('jellyfin-player-offline-media'),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(
                  () => unawaited(_showOfflineMediaSheet()),
                ),
                child: Icon(
                  _offlineMedia.manifest?.complete == true
                      ? CupertinoIcons.check_mark_circled_solid
                      : CupertinoIcons.arrow_down_circle,
                  color: CupertinoColors.white,
                  semanticLabel: l10n.jellyfinOfflineMediaTitle,
                ),
              ),
              if (_tracks.subtitle.isNotEmpty)
                CupertinoButton(
                  key: const ValueKey('jellyfin-player-subtitles'),
                  minimumSize: const Size(48, 48),
                  padding: EdgeInsets.zero,
                  onPressed: _interactionAction(_showSubtitlePicker),
                  child: Icon(
                    CupertinoIcons.captions_bubble,
                    color: CupertinoColors.white,
                    semanticLabel: l10n.jellyfinPlayerSubtitlesButton,
                  ),
                ),
              if (_tracks.audio.length > 1)
                CupertinoButton(
                  key: const ValueKey('jellyfin-player-audio'),
                  minimumSize: const Size(48, 48),
                  padding: EdgeInsets.zero,
                  onPressed: _interactionAction(_showAudioPicker),
                  child: Icon(
                    CupertinoIcons.speaker_2,
                    color: CupertinoColors.white,
                    semanticLabel: l10n.jellyfinPlayerAudioButton,
                  ),
                ),
              CupertinoButton(
                key: const ValueKey('jellyfin-player-quality'),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(_showQualityPicker),
                child: Icon(
                  CupertinoIcons.settings,
                  color: CupertinoColors.white,
                  semanticLabel: l10n.jellyfinPlayerQualityButton,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(AppLocalizations l10n) {
    final maxSeconds = _duration.inSeconds.toDouble();
    final valueSeconds = (_seekDraft ?? _position).inSeconds.toDouble().clamp(
      0.0,
      maxSeconds <= 0 ? 1.0 : maxSeconds,
    );

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                CupertinoColors.black.withValues(alpha: 0.7),
                CupertinoColors.black.withValues(alpha: 0),
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    _formatDuration(_position),
                    style: TextStyle(
                      color: CupertinoColors.white,
                      fontSize: AppText.caption1.fontSize,
                    ),
                  ),
                  Expanded(
                    child: CupertinoSlider(
                      value: valueSeconds,
                      min: 0,
                      max: maxSeconds <= 0 ? 1.0 : maxSeconds,
                      onChangeStart: maxSeconds <= 0
                          ? null
                          : _interactionValueAction(
                              (_) => _seekInteraction = _interactionGeneration,
                            ),
                      onChanged: maxSeconds <= 0
                          ? null
                          : _interactionValueAction((value) {
                              if (_seekInteraction != _interactionGeneration ||
                                  !value.isFinite) {
                                return;
                              }
                              setState(
                                () => _seekDraft = Duration(
                                  seconds: value.clamp(0, maxSeconds).round(),
                                ),
                              );
                            }),
                      onChangeEnd: maxSeconds <= 0
                          ? null
                          : _interactionValueAction((value) {
                              if (_seekInteraction != _interactionGeneration ||
                                  !value.isFinite) {
                                return;
                              }
                              setState(() {
                                _seekInteraction = null;
                                _seekDraft = null;
                              });
                              unawaited(
                                _seekAndBroadcast(
                                  Duration(
                                    seconds: value.clamp(0, maxSeconds).round(),
                                  ),
                                ),
                              );
                            }),
                    ),
                  ),
                  Text(
                    _formatDuration(_duration),
                    style: TextStyle(
                      color: CupertinoColors.white,
                      fontSize: AppText.caption1.fontSize,
                    ),
                  ),
                ],
              ),
              CupertinoButton(
                key: const ValueKey('jellyfin-player-toggle'),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(
                  () => unawaited(_togglePlaying()),
                ),
                child: Icon(
                  _playing
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  color: CupertinoColors.white,
                  size: 36,
                  semanticLabel: _playing
                      ? l10n.entityControlPause
                      : l10n.mediaActionPlay,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
