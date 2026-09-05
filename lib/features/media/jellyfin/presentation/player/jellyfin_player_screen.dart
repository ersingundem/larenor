import 'dart:async';

import '../../../../../core/idle_prevention.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../../../../../core/app_interaction_scope.dart';
import '../../../../../l10n/generated/app_localizations.dart';
import '../../data/jellyfin_client.dart';
import '../../data/models/jellyfin_item.dart';
import '../../providers/jellyfin_providers.dart';
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

  JellyfinClient? _client;
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
    _dragInteraction = null;
    _seekInteraction = null;
    _seekDraft = null;
    _draggingBrightness = false;
    _draggingVolume = false;
    _hideControlsTimer?.cancel();
    _hudTimer?.cancel();
    _hudKind = null;
    _controlsVisible = true;
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
      _expireInteraction();
      _progressPoller.stop();
      unawaited(_reporter?.stop(_position));
      _reporter = null;
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
      setState(() {
        _tracks = const Tracks();
        _currentTrack = const Track();
      });
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
      final reporter = PlaybackReporter(
        client: client,
        itemId: widget.item.id,
        source: source,
      );
      _reporter = reporter;
      await reporter.start(startPosition);
      if (!current()) return false;

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
      _tracksSub?.cancel();
      _tracksSub = _player.stream.tracks.listen((tracks) {
        if (mounted) setState(() => _tracks = tracks);
      });
      _trackSub?.cancel();
      _trackSub = _player.stream.track.listen((track) {
        if (mounted) setState(() => _currentTrack = track);
      });

      _progressPoller.start(immediately: false);
      return true;
    } finally {
      _opening = false;
    }
  }

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

  void _togglePlaying() {
    _ignoreFailure(_player.playOrPause);
    _scheduleHideControls();
  }

  void _seekBy(Duration delta) {
    final target = _position + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    _ignoreFailure(() => _player.seek(clamped));
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

  Future<void> _showSubtitlePicker() {
    final l10n = AppLocalizations.of(context);
    return _pick<SubtitleTrack>(
      title: l10n.jellyfinPlayerSubtitlesTitle,
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
      apply: (track, _) =>
          _ignoreFailure(() => _player.setSubtitleTrack(track)),
    );
  }

  Future<void> _showAudioPicker() {
    final l10n = AppLocalizations.of(context);
    if (_tracks.audio.isEmpty) return Future.value();
    return _pick<AudioTrack>(
      title: l10n.jellyfinPlayerAudioTitle,
      options: List.of(_tracks.audio),
      label: (track) => Text(
        _trackLabel(track, l10n, isOff: false),
        style: track.id == _currentTrack.audio.id
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      ),
      available: (track) =>
          _tracks.audio.any((current) => identical(current, track)),
      apply: (track, _) => _ignoreFailure(() => _player.setAudioTrack(track)),
    );
  }

  Future<void> _showQualityPicker() {
    final l10n = AppLocalizations.of(context);
    return _pick<_QualityOption>(
      title: l10n.jellyfinPlayerQualityTitle,
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
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      navigationBar: _loading || _error != null
          ? CupertinoNavigationBar(
              backgroundColor: CupertinoColors.black,
              leading: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(
                  () => Navigator.of(context).maybePop(),
                ),
                child: const Icon(
                  CupertinoIcons.chevron_back,
                  color: CupertinoColors.white,
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
                if (_controlsVisible) _buildTopBar(l10n),
                if (_controlsVisible) _buildBottomBar(l10n),
              ],
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
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(
                  () => Navigator.of(context).pop(),
                ),
                child: const Icon(
                  CupertinoIcons.chevron_back,
                  color: CupertinoColors.white,
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
              if (_tracks.subtitle.isNotEmpty)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _interactionAction(_showSubtitlePicker),
                  child: const Icon(
                    CupertinoIcons.captions_bubble,
                    color: CupertinoColors.white,
                  ),
                ),
              if (_tracks.audio.length > 1)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _interactionAction(_showAudioPicker),
                  child: const Icon(
                    CupertinoIcons.speaker_2,
                    color: CupertinoColors.white,
                  ),
                ),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(_showQualityPicker),
                child: const Icon(
                  CupertinoIcons.settings,
                  color: CupertinoColors.white,
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
                              _ignoreFailure(
                                () => _player.seek(
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
                padding: EdgeInsets.zero,
                onPressed: _interactionAction(_togglePlaying),
                child: Icon(
                  _playing
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  color: CupertinoColors.white,
                  size: 36,
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
