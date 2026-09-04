import 'dart:async';

import 'package:flutter/widgets.dart';

/// Polls after the previous read finishes, with at most one pending refresh.
/// Pauses while the app is not resumed; it never cancels or retries a write.
class ForegroundPoller with WidgetsBindingObserver {
  ForegroundPoller({
    required Duration interval,
    required Future<void> Function() poll,
    void Function(Object error, StackTrace stack)? onError,
  }) : // Public constructor names intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _interval = interval,
       // ignore: prefer_initializing_formals
       _poll = poll,
       // ignore: prefer_initializing_formals
       _onError = onError;

  final Future<void> Function() _poll;
  final void Function(Object, StackTrace)? _onError;
  Duration _interval;
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _running = false;
  bool _pending = false;
  bool _foreground = true;

  bool get isActive => _started && !_disposed && _foreground;

  set interval(Duration value) {
    _interval = value;
    if (!_running) _schedule();
  }

  void start({bool immediately = true}) {
    if (_started || _disposed) return;
    _started = true;
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    if (immediately) {
      refresh();
    } else {
      _schedule();
    }
  }

  void refresh() {
    if (!isActive) return;
    _timer?.cancel();
    if (_running) {
      _pending = true;
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    _running = true;
    _pending = false;
    try {
      await _poll();
    } catch (error, stack) {
      // A read failure must not become an unhandled timer Future or terminate
      // future polling. Callers can retain their last data or expose an error.
      if (!_disposed) _onError?.call(error, stack);
    } finally {
      _running = false;
      if (_pending && isActive) {
        _pending = false;
        refresh();
      } else {
        _schedule();
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (isActive) _timer = Timer(_interval, refresh);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_foreground) refresh();
  }

  void stop() {
    _timer?.cancel();
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _started = false;
    _pending = false;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    if (_started) WidgetsBinding.instance.removeObserver(this);
  }
}
