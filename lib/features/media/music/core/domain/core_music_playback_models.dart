import 'core_music_target_models.dart';

enum CoreMusicPlaybackOperation {
  play,
  pause,
  next,
  previous,
  seek,
  volume;

  String get wire => name;

  String get capability => switch (this) {
    CoreMusicPlaybackOperation.play => 'play',
    CoreMusicPlaybackOperation.pause => 'pause',
    CoreMusicPlaybackOperation.next ||
    CoreMusicPlaybackOperation.previous => 'next_previous',
    CoreMusicPlaybackOperation.seek => 'seek',
    CoreMusicPlaybackOperation.volume => 'volume_set',
  };
}

enum CoreMusicReceiptState { succeeded, needsAttention }

class CoreMusicPlaybackReceipt {
  const CoreMusicPlaybackReceipt({
    required this.requestId,
    required this.targetId,
    required this.operation,
    required this.state,
    required this.playerRevision,
  });

  final String requestId;
  final String targetId;
  final CoreMusicPlaybackOperation operation;
  final CoreMusicReceiptState state;
  final int playerRevision;

  @override
  String toString() =>
      'CoreMusicPlaybackReceipt(operation: ${operation.name}, state: ${state.name}, revision: $playerRevision)';
}

/// Secret-free state projected to Android Media3. Native actions still require
/// a short-lived, revision-bound authorization lease before reaching Core.
class CoreMusicMediaSessionState {
  const CoreMusicMediaSessionState({
    this.targetId,
    this.title,
    this.positionSeconds = 0,
    this.durationSeconds,
    this.isPlaying = false,
    this.isGroup = false,
    this.canPlay = false,
    this.canPause = false,
    this.canNext = false,
    this.canPrevious = false,
  });

  factory CoreMusicMediaSessionState.fromTarget(CoreMusicTarget? target) {
    if (target == null || !target.available || !target.enabled) {
      return const CoreMusicMediaSessionState();
    }
    final now = target.queue?.nowPlaying;
    return CoreMusicMediaSessionState(
      targetId: target.id,
      title: now?.title,
      positionSeconds: now?.positionSeconds ?? 0,
      durationSeconds: now?.durationSeconds,
      isPlaying: target.playbackState == 'playing',
      isGroup: target.kind == CoreMusicTargetKind.group,
      canPlay: target.capabilities.contains('play'),
      canPause: target.capabilities.contains('pause'),
      canNext: target.capabilities.contains('next_previous'),
      canPrevious: target.capabilities.contains('next_previous'),
    );
  }

  final String? targetId;
  final String? title;
  final int positionSeconds;
  final int? durationSeconds;
  final bool isPlaying;
  final bool isGroup;
  final bool canPlay;
  final bool canPause;
  final bool canNext;
  final bool canPrevious;

  bool get active => targetId != null;

  @override
  String toString() =>
      'CoreMusicMediaSessionState(active: $active, playing: $isPlaying)';
}
