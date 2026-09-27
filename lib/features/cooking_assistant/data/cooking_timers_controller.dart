import 'package:flutter/foundation.dart';

import '../domain/cooking_timer.dart';

abstract interface class CookingTimerClock {
  Duration get wallNow;
  Duration get monotonicNow;
}

final class SystemCookingTimerClock implements CookingTimerClock {
  SystemCookingTimerClock() : _monotonic = Stopwatch()..start();
  final Stopwatch _monotonic;
  @override
  Duration get wallNow =>
      Duration(microseconds: DateTime.now().toUtc().microsecondsSinceEpoch);
  @override
  Duration get monotonicNow => _monotonic.elapsed;
}

abstract interface class CookingTimerStore {
  Future<List<CookingTimer>> read(String accountId, String recipeSessionId);
  Future<void> write(CookingTimer timer, {required int expectedRevision});
}

abstract interface class MutableCookingTimerStore implements CookingTimerStore {
  Future<void> remove(
    String accountId,
    String recipeSessionId,
    String timerId, {
    required int expectedRevision,
  });
}

abstract interface class CookingTimerNotifications {
  /// Implementations must deduplicate [idempotencyKey] durably.
  Future<void> finished({
    required String idempotencyKey,
    required String label,
  });
}

enum CookingTimerFailure { unavailable, staleAuthority, invalidRecord, limit }

final class CookingTimersController extends ChangeNotifier {
  CookingTimersController({
    required this.store,
    required this.notifications,
    required this.clock,
    required this.authority,
    required this.isCurrent,
    this.maximumTimers = 8,
    this.maximumDuration = const Duration(days: 7),
  }) : _anchorWall = clock.wallNow,
       _anchorMonotonic = clock.monotonicNow;

  final CookingTimerStore store;
  final CookingTimerNotifications notifications;
  final CookingTimerClock clock;
  final CookingTimerAuthority authority;
  final bool Function() isCurrent;
  final int maximumTimers;
  final Duration maximumDuration;
  final Duration _anchorWall;
  final Duration _anchorMonotonic;
  final List<CookingTimer> _timers = [];
  int _operation = 0;
  int _identifier = 0;
  bool _retired = false;
  bool busy = false;
  bool _resuming = false;
  int restoreCount = 0;
  CookingTimerFailure? failure;

  List<CookingTimer> get timers => List.unmodifiable(_timers);

  bool _current() {
    if (_retired) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  Duration get _estimatedWall {
    final elapsed = clock.monotonicNow - _anchorMonotonic;
    return _anchorWall + (elapsed.isNegative ? Duration.zero : elapsed);
  }

  Duration remaining(CookingTimer timer) {
    final value = timer.deadlineWall - _estimatedWall;
    return value.isNegative ? Duration.zero : value;
  }

  bool _valid(CookingTimer value) =>
      value.accountId == authority.accountId &&
      value.recipeSessionId == authority.recipeSessionId &&
      value.id.isNotEmpty &&
      value.label.trim().isNotEmpty &&
      value.revision > 0 &&
      value.deadlineWall >= Duration.zero;

  Future<void> restore() async {
    if (!_current()) {
      failure = CookingTimerFailure.staleAuthority;
      return;
    }
    if (busy) return;
    final operation = ++_operation;
    busy = true;
    try {
      final values = await store.read(
        authority.accountId,
        authority.recipeSessionId,
      );
      if (operation != _operation || !_current()) {
        failure = CookingTimerFailure.staleAuthority;
        return;
      }
      if (values.length > maximumTimers ||
          values.any((value) => !_valid(value))) {
        failure = CookingTimerFailure.invalidRecord;
        return;
      }
      final sorted = List<CookingTimer>.of(values)
        ..sort((a, b) => a.deadlineWall.compareTo(b.deadlineWall));
      _timers
        ..clear()
        ..addAll(sorted);
      restoreCount++;
      failure = null;
      notifyListeners();
      await resume(allowBusy: true);
    } catch (_) {
      if (operation == _operation && _current()) {
        failure = CookingTimerFailure.unavailable;
        notifyListeners();
      }
    } finally {
      if (operation == _operation && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> start({
    required String label,
    required Duration duration,
  }) async {
    if (!_current()) {
      failure = CookingTimerFailure.staleAuthority;
      return false;
    }
    if (busy) return false;
    final normalized = label.trim();
    if (normalized.isEmpty ||
        normalized.length > 100 ||
        duration <= Duration.zero ||
        duration > maximumDuration) {
      return false;
    }
    if (_timers.length >= maximumTimers) {
      failure = CookingTimerFailure.limit;
      return false;
    }
    final operation = ++_operation;
    busy = true;
    final value = CookingTimer(
      id: 'timer-${_estimatedWall.inMicroseconds}-${_identifier++}',
      accountId: authority.accountId,
      recipeSessionId: authority.recipeSessionId,
      label: normalized,
      deadlineWall: _estimatedWall + duration,
      revision: 1,
      notified: false,
      acknowledged: false,
    );
    try {
      await store.write(value, expectedRevision: 0);
      if (operation != _operation || !_current()) {
        failure = CookingTimerFailure.staleAuthority;
        return false;
      }
      _timers.add(value);
      _timers.sort((a, b) => a.deadlineWall.compareTo(b.deadlineWall));
      failure = null;
      notifyListeners();
      return true;
    } catch (_) {
      if (operation == _operation && _current()) {
        failure = CookingTimerFailure.unavailable;
        notifyListeners();
      }
      return false;
    } finally {
      if (operation == _operation && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> resume({bool allowBusy = false}) async {
    if (!_current()) {
      failure = CookingTimerFailure.staleAuthority;
      return;
    }
    if (_resuming || busy && !allowBusy) return;
    _resuming = true;
    final expired = _timers
        .where((timer) => remaining(timer) == Duration.zero && !timer.notified)
        .toList(growable: false);
    try {
      for (final timer in expired) {
        if (!_current()) {
          failure = CookingTimerFailure.staleAuthority;
          return;
        }
        try {
          await notifications.finished(
            idempotencyKey:
                'cooking:${authority.accountId}:${authority.recipeSessionId}:${timer.id}:finished-v1',
            label: timer.label,
          );
          if (!_current()) {
            failure = CookingTimerFailure.staleAuthority;
            return;
          }
          final updated = timer.copyWith(
            revision: timer.revision + 1,
            notified: true,
          );
          await store.write(updated, expectedRevision: timer.revision);
          if (!_current()) {
            failure = CookingTimerFailure.staleAuthority;
            return;
          }
          _replace(updated);
        } catch (_) {
          if (_current()) failure = CookingTimerFailure.unavailable;
          return;
        }
      }
      notifyListeners();
    } finally {
      _resuming = false;
    }
  }

  Future<bool> acknowledge(String id) async {
    if (!_current()) {
      failure = CookingTimerFailure.staleAuthority;
      return false;
    }
    if (busy) return false;
    final index = _timers.indexWhere((value) => value.id == id);
    if (index < 0 || remaining(_timers[index]) > Duration.zero) return false;
    final timer = _timers[index];
    if (timer.acknowledged) return true;
    final operation = ++_operation;
    busy = true;
    final updated = timer.copyWith(
      revision: timer.revision + 1,
      acknowledged: true,
    );
    try {
      await store.write(updated, expectedRevision: timer.revision);
      if (operation != _operation || !_current()) {
        failure = CookingTimerFailure.staleAuthority;
        return false;
      }
      _replace(updated);
      failure = null;
      notifyListeners();
      return true;
    } catch (_) {
      if (operation == _operation && _current()) {
        failure = CookingTimerFailure.unavailable;
        notifyListeners();
      }
      return false;
    } finally {
      if (operation == _operation && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> cancel(String id) async {
    if (!_current()) {
      failure = CookingTimerFailure.staleAuthority;
      return false;
    }
    if (busy) return false;
    final mutable = store;
    if (mutable is! MutableCookingTimerStore) {
      failure = CookingTimerFailure.unavailable;
      notifyListeners();
      return false;
    }
    final index = _timers.indexWhere((timer) => timer.id == id);
    if (index < 0) return false;
    final timer = _timers[index];
    final operation = ++_operation;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      await mutable.remove(
        authority.accountId,
        authority.recipeSessionId,
        timer.id,
        expectedRevision: timer.revision,
      );
      if (operation != _operation || !_current()) {
        failure = CookingTimerFailure.staleAuthority;
        return false;
      }
      _timers.removeWhere((value) => value.id == timer.id);
      return true;
    } catch (_) {
      failure = operation == _operation && _current()
          ? CookingTimerFailure.unavailable
          : CookingTimerFailure.staleAuthority;
      return false;
    } finally {
      if (operation == _operation && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void _replace(CookingTimer value) {
    final index = _timers.indexWhere((timer) => timer.id == value.id);
    if (index >= 0) _timers[index] = value;
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _operation++;
    busy = false;
    _resuming = false;
    failure = CookingTimerFailure.staleAuthority;
    notifyListeners();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
