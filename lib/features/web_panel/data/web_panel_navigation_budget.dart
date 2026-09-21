/// Limits redirect/download loops without assuming a navigation is a user tap.
/// It is reset only when a new page session is explicitly created.
class WebPanelNavigationBudget {
  WebPanelNavigationBudget({DateTime Function()? now})
    : _now = now ?? _monotonicClock();
  final DateTime Function() _now;
  static DateTime Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => DateTime.fromMicrosecondsSinceEpoch(
      watch.elapsedMicroseconds,
      isUtc: true,
    );
  }

  DateTime? _windowStart;
  int _count = 0;
  bool take() {
    final now = _now();
    if (_windowStart == null ||
        now.difference(_windowStart!) >= const Duration(seconds: 30)) {
      _windowStart = now;
      _count = 0;
    }
    return ++_count <= 20;
  }
}

/// Bounds both manual retry and renderer-process recovery. A panel can never
/// turn a repeated engine crash into an unbounded reload loop.
class WebPanelRecoveryBudget {
  WebPanelRecoveryBudget({DateTime Function()? now})
    : _now = now ?? WebPanelNavigationBudget._monotonicClock();
  final DateTime Function() _now;
  DateTime? _windowStart, _lastAttempt;
  int _count = 0;

  bool take() {
    final now = _now();
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < const Duration(seconds: 2)) {
      return false;
    }
    if (_windowStart == null ||
        now.difference(_windowStart!) >= const Duration(minutes: 5)) {
      _windowStart = now;
      _count = 0;
    }
    if (_count >= 3) return false;
    _count++;
    _lastAttempt = now;
    return true;
  }
}
