import 'dart:async';

/// Process-wide serialization for configuration writes and vault snapshots.
/// Enqueue a complete multi-key operation before its first asynchronous read.
/// Nested awaited storage operations share their caller's queue ownership.
/// Every write must be awaited; detached work must not escape an operation.
abstract final class ConfigurationWrites {
  static Future<void>? _pending;
  static final _owner = Object();

  static Future<T> run<T>(Future<T> Function() operation) {
    if (Zone.current[_owner] == true) return operation();
    final previous = _pending;
    Future<T> start() =>
        runZoned(() => Future<T>.sync(operation), zoneValues: {_owner: true});
    final next = previous == null ? start() : previous.then((_) => start());
    late final Future<void> tail;
    void release() {
      // Drop the completed future and its zone when the queue becomes idle.
      if (identical(_pending, tail)) _pending = null;
    }

    tail = next.then<void>(
      (_) => release(),
      onError: (Object _, StackTrace _) => release(),
    );
    _pending = tail;
    return next;
  }
}
