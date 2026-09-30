import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../data/camera_clip_player.dart';
import '../data/clip/camera_clip_source.dart';
import '../domain/camera_search_models.dart';

class CameraClipScreen extends StatefulWidget {
  const CameraClipScreen({
    super.key,
    required this.evidence,
    required this.load,
    required this.isCurrent,
    required this.onClose,
    this.playerFactory,
    this.sourceFactory,
    this.onRetire,
  });
  final CameraSearchEvidence evidence;
  final Future<Uint8List> Function() load;
  final bool Function() isCurrent;
  final VoidCallback onClose;
  final CameraClipPlayer Function()? playerFactory;
  final Future<CameraClipSource> Function(Uint8List)? sourceFactory;
  final VoidCallback? onRetire;
  @override
  State<CameraClipScreen> createState() => _CameraClipScreenState();
}

class _CameraClipScreenState extends State<CameraClipScreen>
    with WidgetsBindingObserver {
  CameraClipPlayer? _player;
  CameraClipSource? _source;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _loading = true,
      _playing = false,
      _buffering = false,
      _failed = false,
      _retired = false;
  bool _foreground = true;
  int _epoch = 0;
  Duration _position = Duration.zero, _duration = Duration.zero;
  double? _seekDraft;
  Timer? _guard;
  bool _disposing = false;
  bool get _current {
    try {
      return mounted && !_retired && _foreground && widget.isCurrent();
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _guard = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_current) _retire();
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    final epoch = ++_epoch;
    Uint8List? bytes;
    CameraClipSource? pending;
    try {
      if (!_current) return;
      bytes = await widget.load();
      if (!_current || epoch != _epoch) return;
      pending = await (widget.sourceFactory ?? createCameraClipSource)(bytes);
      bytes.fillRange(0, bytes.length, 0);
      bytes = null;
      if (!_current || epoch != _epoch) return;
      _source = pending;
      pending = null;
      final player = (widget.playerFactory ?? MediaKitCameraClipPlayer.new)();
      _player = player;
      void changed(void Function() update) {
        if (!_current) {
          _retire();
          return;
        }
        setState(update);
      }

      _subscriptions.addAll([
        player.playing.listen((v) => changed(() => _playing = v)),
        player.buffering.listen((v) => changed(() => _buffering = v)),
        player.position.listen((v) => changed(() => _position = v)),
        player.duration.listen((v) => changed(() => _duration = v)),
        player.errors.listen((_) {
          _fail();
        }),
      ]);
      // Construct the video surface before opening to bind native video output.
      if (mounted) setState(() => _loading = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!_current || epoch != _epoch) return;
      await player.open(_source!.uri);
      if (!_current) _retire();
    } catch (_) {
      if (mounted && epoch == _epoch) _fail();
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      await pending?.dispose();
    }
  }

  void _fail() {
    if (!mounted || _retired) return;
    setState(() {
      _failed = true;
      _loading = false;
    });
    _retire();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    widget.onRetire?.call();
    _epoch++;
    _guard?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final player = _player, source = _source;
    _player = null;
    _source = null;
    unawaited(
      () async {
        try {
          await player?.dispose();
        } finally {
          await source?.dispose();
        }
      }().catchError((Object _) {}),
    );
    if (mounted && !_disposing) setState(() {});
  }

  Future<void> _toggle() async {
    if (!_current || _player == null) return;
    try {
      await _player!.toggle();
    } catch (_) {
      _fail();
    }
  }

  Future<void> _seek(double value) async {
    if (!_current || _player == null) return;
    setState(() => _seekDraft = null);
    try {
      await _player!.seek(Duration(milliseconds: value.round()));
    } catch (_) {
      _fail();
    }
  }

  void _close() {
    _retire();
    widget.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _retire();
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _retire();
    super.dispose();
  }

  String _time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 86400);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unavailable = _failed || _retired;
    final total = _duration.inMilliseconds.clamp(0, 86400000).toDouble();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () =>
            unawaited(_toggle()),
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Focus(
        autofocus: true,
        child: CupertinoPageScaffold(
          backgroundColor: AppColors.canvas.resolveFrom(context),
          navigationBar: CupertinoNavigationBar(
            middle: Text(l.cameraSearchClipTitle),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 48),
              onPressed: _close,
              child: Text(l.cameraSearchClipBack),
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: SizedBox(
                              height: (box.maxWidth * 9 / 16).clamp(180, 500),
                              child: ColoredBox(
                                color: CupertinoColors.black,
                                child: unavailable
                                    ? Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: Semantics(
                                            liveRegion: true,
                                            child: Text(
                                              l.cameraSearchClipUnavailable,
                                              style: AppText.body.copyWith(
                                                color: CupertinoColors.white,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        ),
                                      )
                                    : _loading
                                    ? const Center(
                                        child: CupertinoActivityIndicator(
                                          color: CupertinoColors.white,
                                        ),
                                      )
                                    : Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Positioned.fill(
                                            child: Semantics(
                                              label: l.cameraSearchClipTitle,
                                              child: _player!.surface(),
                                            ),
                                          ),
                                          if (_buffering)
                                            const CupertinoActivityIndicator(
                                              color: CupertinoColors.white,
                                            ),
                                        ],
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            widget.evidence.capturedAt
                                .toLocal()
                                .toString()
                                .split('.')
                                .first,
                            style: AppText.headline,
                          ),
                          const SizedBox(height: 12),
                          if (!unavailable && !_loading) ...[
                            Semantics(
                              label: l.cameraSearchClipSeek,
                              value:
                                  '${_time(_position)} / ${_time(_duration)}',
                              child: CupertinoSlider(
                                key: const ValueKey('camera-clip-seek'),
                                max: total > 0 ? total : 1,
                                value:
                                    (_seekDraft ??
                                            _position.inMilliseconds.toDouble())
                                        .clamp(0, total > 0 ? total : 1),
                                onChanged: total > 0 && _current
                                    ? (v) => setState(() => _seekDraft = v)
                                    : null,
                                onChangeEnd: total > 0 && _current
                                    ? (v) => unawaited(_seek(v))
                                    : null,
                              ),
                            ),
                            Text(
                              '${_time(_position)} / ${_time(_duration)}',
                              style: AppText.footnote,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Center(
                              child: CupertinoButton.filled(
                                key: const ValueKey('camera-clip-play'),
                                minimumSize: const Size(64, 48),
                                onPressed: _current
                                    ? () => unawaited(_toggle())
                                    : null,
                                child: Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Icon(
                                      _playing
                                          ? CupertinoIcons.pause_fill
                                          : CupertinoIcons.play_fill,
                                    ),
                                    Text(
                                      _playing
                                          ? l.cameraSearchClipPause
                                          : l.cameraSearchClipPlay,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          Text(
                            l.cameraSearchClipPrivate,
                            style: AppText.footnote,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
