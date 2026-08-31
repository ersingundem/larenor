import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/jellyfin_client.dart';
import '../../data/models/jellyfin_item.dart';
import '../../providers/jellyfin_providers.dart';

/// Full-screen playback: negotiates a Jellyfin `PlaybackInfo` source (Direct
/// Play whenever our declared `DeviceProfile` allows it), plays it through
/// `media_kit` (hardware-accelerated via libmpv), and reports start/progress
/// (every 10s)/stop back to Jellyfin so resume/continue-watching works.
class JellyfinPlayerScreen extends ConsumerStatefulWidget {
  const JellyfinPlayerScreen({super.key, required this.item});

  final JellyfinItem item;

  @override
  ConsumerState<JellyfinPlayerScreen> createState() =>
      _JellyfinPlayerScreenState();
}

class _JellyfinPlayerScreenState extends ConsumerState<JellyfinPlayerScreen> {
  final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  JellyfinClient? _client;
  JellyfinPlaybackSource? _source;
  Timer? _progressTimer;
  StreamSubscription<Duration>? _positionSub;
  Duration _position = Duration.zero;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final client = ref.read(jellyfinClientProvider);
    if (client == null) {
      setState(() {
        _error = 'Not connected to Jellyfin.';
        _loading = false;
      });
      return;
    }
    _client = client;

    try {
      final source = await client.getPlaybackInfo(widget.item.id);
      _source = source;
      await _player.open(Media(source.streamUrl));
      await client.reportPlaybackStart(itemId: widget.item.id, source: source);

      _positionSub = _player.stream.position.listen(
        (position) => _position = position,
      );
      _progressTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _reportProgress(),
      );

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _reportProgress() async {
    final client = _client;
    final source = _source;
    if (client == null || source == null) return;
    await client.reportPlaybackProgress(
      itemId: widget.item.id,
      source: source,
      position: _position,
      isPaused: !_player.state.playing,
    );
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _positionSub?.cancel();
    final client = _client;
    final source = _source;
    if (client != null && source != null) {
      // Fire-and-forget: best-effort telemetry, dispose() can't be async.
      client.reportPlaybackStopped(
        itemId: widget.item.id,
        source: source,
        position: _position,
      );
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.black.withValues(alpha: 0.6),
        border: null,
        middle: Text(
          widget.item.name,
          style: const TextStyle(color: CupertinoColors.white),
        ),
      ),
      child: Center(
        child: _loading
            ? const CupertinoActivityIndicator(color: CupertinoColors.white)
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CupertinoColors.white),
                ),
              )
            : Video(controller: _controller),
      ),
    );
  }
}
