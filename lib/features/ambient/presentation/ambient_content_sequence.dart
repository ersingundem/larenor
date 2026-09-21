import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../web_panel/presentation/web_panel_view.dart';
import '../data/ambient_content_repository.dart';
import '../domain/ambient_content.dart';

typedef AmbientContentRenderer = Widget Function(
  AmbientContent item,
  Uint8List? bytes,
  bool active,
  VoidCallback next,
);

/// Loads one verified item at a time. Broken entries are skipped once per pass;
/// inactive/background owners retire timers and late reads immediately.
class AmbientContentSequence extends StatefulWidget {
  const AmbientContentSequence({
    super.key,
    required this.repository,
    required this.items,
    required this.interval,
    required this.active,
    required this.reducedMotion,
    this.renderer,
    this.placeholder = const SizedBox.expand(),
  });

  final AmbientContentStore repository;
  final List<AmbientContent> items;
  final Duration interval;
  final bool active;
  final bool reducedMotion;
  final AmbientContentRenderer? renderer;
  final Widget placeholder;

  @override
  State<AmbientContentSequence> createState() => _AmbientContentSequenceState();
}

class _AmbientContentSequenceState extends State<AmbientContentSequence> {
  Timer? _timer;
  int _index = 0, _generation = 0;
  AmbientContent? _item;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(covariant AmbientContentSequence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.items != widget.items ||
        !identical(oldWidget.repository, widget.repository)) {
      _restart();
    } else if (oldWidget.interval != widget.interval) {
      _schedule();
    }
  }

  void _restart() {
    _generation++;
    _timer?.cancel();
    _item = null;
    _bytes = null;
    _index = 0;
    if (widget.active && widget.items.isNotEmpty) {
      unawaited(_load(_generation));
    }
  }

  Future<void> _load(int generation) async {
    final items = List<AmbientContent>.of(widget.items);
    for (var attempt = 0; attempt < items.length; attempt++) {
      if (!_current(generation)) return;
      final item = items[_index];
      try {
        final bytes = item.kind == AmbientContentKind.web
            ? null
            : await widget.repository
                  .readLocal(item)
                  .timeout(const Duration(seconds: 15));
        if (!_current(generation)) return;
        setState(() {
          _item = item;
          _bytes = bytes;
        });
        _schedule();
        return;
      } catch (_) {
        if (!_current(generation)) return;
        _index = (_index + 1) % items.length;
      }
    }
    if (_current(generation)) {
      setState(() {
        _item = null;
        _bytes = null;
      });
    }
  }

  bool _current(int generation) =>
      mounted && widget.active && generation == _generation;

  void _schedule() {
    _timer?.cancel();
    if (!widget.active || widget.items.length < 2 || _item == null) return;
    _timer = Timer(widget.interval, _next);
  }

  void _next() {
    if (!mounted || !widget.active || widget.items.isEmpty) return;
    _timer?.cancel();
    setState(() {
      _item = null;
      _bytes = null;
      _index = (_index + 1) % widget.items.length;
    });
    unawaited(_load(_generation));
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    if (!widget.active || item == null) return widget.placeholder;
    final generation = _generation;
    void nextIfCurrent() {
      if (_current(generation) && identical(_item, item)) _next();
    }

    final renderer = widget.renderer;
    final child = renderer != null
        ? renderer(item, _bytes, widget.active, nextIfCurrent)
        : _AmbientContentSurface(
            item: item,
            bytes: _bytes,
            active: widget.active,
            reducedMotion: widget.reducedMotion,
            onComplete: nextIfCurrent,
          );
    return AnimatedSwitcher(
      duration: widget.reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 350),
      child: KeyedSubtree(key: ValueKey(item.id), child: child),
    );
  }
}

class _AmbientContentSurface extends StatelessWidget {
  const _AmbientContentSurface({
    required this.item,
    required this.bytes,
    required this.active,
    required this.reducedMotion,
    required this.onComplete,
  });

  final AmbientContent item;
  final Uint8List? bytes;
  final bool active, reducedMotion;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) => switch (item.kind) {
    AmbientContentKind.video =>
      reducedMotion
          ? const _ReducedMotionVideo()
          : _AmbientVideo(
              bytes: bytes!,
              active: active,
              onComplete: onComplete,
            ),
    AmbientContentKind.pdf => IgnorePointer(
      child: PdfViewer.data(
        bytes!,
        sourceName: item.id,
        params: const PdfViewerParams(
          panEnabled: false,
          scaleEnabled: false,
          enableKeyboardNavigation: false,
          forceEnableTextSemantics: false,
        ),
      ),
    ),
    AmbientContentKind.web => WebPanelView(
      policy: item.policy,
      sourceIdentity: item.id,
      sourceCurrent: () => active,
      requireActiveInteraction: false,
    ),
  };
}

class _ReducedMotionVideo extends StatelessWidget {
  const _ReducedMotionVideo();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    key: ValueKey('ambient-video-reduced-motion'),
    color: CupertinoColors.black,
    child: Center(
      child: Icon(
        CupertinoIcons.play_rectangle,
        color: CupertinoColors.systemGrey,
        size: 72,
      ),
    ),
  );
}

class _AmbientVideo extends StatefulWidget {
  const _AmbientVideo({
    required this.bytes,
    required this.active,
    required this.onComplete,
  });
  final Uint8List bytes;
  final bool active;
  final VoidCallback onComplete;

  @override
  State<_AmbientVideo> createState() => _AmbientVideoState();
}

class _AmbientVideoState extends State<_AmbientVideo> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<bool>? _completed;
  int _generation = 0;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _foreground = state == AppLifecycleState.resumed;
        _sync();
      },
    );
    _completed = _player.stream.completed.where((value) => value).listen((_) {
      if (mounted && widget.active && _foreground) widget.onComplete();
    });
    unawaited(_open(++_generation));
  }

  @override
  void didUpdateWidget(covariant _AmbientVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      unawaited(_open(++_generation));
    } else {
      _sync();
    }
  }

  Future<void> _open(int generation) async {
    try {
      final media = await Media.memory(widget.bytes, type: 'video/mp4');
      if (!mounted || generation != _generation || !widget.active) {
        return;
      }
      await _player.setVolume(0);
      if (!mounted || generation != _generation || !widget.active) {
        return;
      }
      // Opening never autoplays: a foreground/route change can arrive while
      // native media setup is pending. Verify the owner again after every await.
      await _player.open(media, play: false);
      if (!mounted ||
          generation != _generation ||
          !widget.active ||
          !_foreground) {
        await _player.pause();
        return;
      }
      await _player.play();
      if (!mounted ||
          generation != _generation ||
          !widget.active ||
          !_foreground) {
        await _player.pause();
      }
    } catch (_) {
      if (mounted &&
          generation == _generation &&
          widget.active &&
          _foreground) {
        widget.onComplete();
      }
    }
  }

  void _sync() {
    if (!mounted) return;
    if (widget.active && _foreground) {
      unawaited(_player.play());
    } else {
      unawaited(_player.pause());
    }
  }

  @override
  void dispose() {
    _generation++;
    _lifecycle.dispose();
    unawaited(_completed?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Video(controller: _controller, controls: null, fit: BoxFit.contain);
}
