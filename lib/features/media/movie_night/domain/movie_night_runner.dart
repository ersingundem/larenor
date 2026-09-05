import 'movie_night_preset.dart';

enum MovieNightOutcome {
  finished,
  cancelled,
  sceneFailed,
  playbackFailed,
  alreadyStarted,
}

/// One explicitly approved run. Never retries a mutation or reverses a scene;
/// the separately chosen finishing scene requires a second user action.
class MovieNightRunner {
  MovieNightRunner({
    required this.preset,
    required this.isCurrent,
    required this.activate,
    required this.play,
  });
  final MovieNightPreset preset;
  final bool Function() isCurrent;
  final Future<void> Function(String entityId) activate;
  final Future<bool> Function() play;
  bool _started = false;
  bool _canFinish = false;
  bool _finishConsumed = false;

  bool get canFinish =>
      _canFinish &&
      !_finishConsumed &&
      preset.finishEntityId != null &&
      isCurrent();

  Future<MovieNightOutcome> run() async {
    if (_started) return MovieNightOutcome.alreadyStarted;
    _started = true;
    if (!isCurrent()) return MovieNightOutcome.cancelled;
    try {
      await activate(preset.startEntityId);
    } catch (_) {
      return MovieNightOutcome.sceneFailed;
    }
    if (!isCurrent()) return MovieNightOutcome.cancelled;
    // Allow an explicitly selected finishing scene even if playback fails:
    // it is not a rollback, and its contents are defined by the user in HA.
    try {
      final opened = await play();
      _canFinish = true;
      if (!isCurrent()) return MovieNightOutcome.cancelled;
      return opened
          ? MovieNightOutcome.finished
          : MovieNightOutcome.playbackFailed;
    } catch (_) {
      _canFinish = true;
      return MovieNightOutcome.playbackFailed;
    }
  }

  Future<bool> finish() async {
    if (!canFinish) return false;
    _finishConsumed = true;
    try {
      await activate(preset.finishEntityId!);
      return isCurrent();
    } catch (_) {
      return false;
    }
  }
}
