import 'dart:async';

import '../../data/jellyfin_client.dart';

/// Best-effort session reporting. Slow progress calls never overlap, and a
/// stopped session cannot send a later progress update or duplicate its stop.
/// Failed writes are deliberately not retried.
class PlaybackReporter {
  PlaybackReporter({
    required this.client,
    required this.itemId,
    required this.source,
  });

  final JellyfinClient client;
  final String itemId;
  final JellyfinPlaybackSource source;
  Future<void>? _starting;
  Future<void>? _progress;
  Future<void>? _stopping;
  bool _closed = false;

  Future<void> start(Duration position) => _starting ??= _bestEffort(
    () => client.reportPlaybackStart(
      itemId: itemId,
      source: source,
      position: position,
    ),
  );

  Future<void> progress(Duration position, {required bool isPaused}) async {
    if (_closed || _progress != null) return;
    final operation = _bestEffort(() async {
      await _starting;
      if (_closed) return;
      await client.reportPlaybackProgress(
        itemId: itemId,
        source: source,
        position: position,
        isPaused: isPaused,
      );
    });
    _progress = operation;
    await operation;
    if (identical(_progress, operation)) _progress = null;
  }

  Future<void> stop(Duration position) {
    if (_stopping != null) return _stopping!;
    _closed = true;
    return _stopping = _bestEffort(() async {
      await _starting;
      await _progress;
      await client.reportPlaybackStopped(
        itemId: itemId,
        source: source,
        position: position,
      );
    });
  }

  Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Telemetry failure must not interrupt local playback or escape dispose.
    }
  }
}
