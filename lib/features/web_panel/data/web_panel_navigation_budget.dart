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
