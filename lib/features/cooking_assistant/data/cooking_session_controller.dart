import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/cooking_session.dart';

abstract interface class CookingSessionGateway {
  Future<CookingSession> move({
    required String sessionId,
    required int expectedRevision,
    required int step,
  });
}

enum CookingSessionFailure { unavailable, staleAuthority, invalidResponse }

final class CookingSessionController extends ChangeNotifier {
  CookingSessionController({
    required this.gateway,
    required CookingSession initial,
    required this.isCurrent,
  }) : _value = initial;

  final CookingSessionGateway gateway;
  final bool Function() isCurrent;
  CookingSession _value;
  CookingSession get value => _value;
  CookingSessionFailure? failure;
  bool busy = false;
  bool _retired = false;
  int _epoch = 0;
  final Set<Timer> _timers = {};
  int get activeTimerCount => _timers.length;

  bool _hasAuthority() {
    if (_retired) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<bool> next() => _move(_value.currentStep + 1);
  Future<bool> previous() => _move(_value.currentStep - 1);

  Future<bool> _move(int step) async {
    if (!_hasAuthority() || busy || step < 0 || step >= _value.steps.length) {
      return false;
    }
    final operation = ++_epoch;
    final original = _value;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final result = await gateway.move(
        sessionId: original.id,
        expectedRevision: original.revision,
        step: step,
      );
      if (operation != _epoch || !_hasAuthority()) {
        failure = CookingSessionFailure.staleAuthority;
        return false;
      }
      if (result.id != original.id ||
          result.accountId != original.accountId ||
          result.recipeId != original.recipeId ||
          result.recipeRevision != original.recipeRevision ||
          result.steps.length != original.steps.length ||
          !listEquals(result.steps, original.steps) ||
          result.revision != original.revision + 1 ||
          result.currentStep != step) {
        failure = CookingSessionFailure.invalidResponse;
        return false;
      }
      _value = result;
      return true;
    } catch (_) {
      if (operation == _epoch && _hasAuthority()) {
        failure = CookingSessionFailure.unavailable;
      } else {
        failure = CookingSessionFailure.staleAuthority;
      }
      return false;
    } finally {
      if (operation == _epoch && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void startTimer(Duration duration, {required VoidCallback onElapsed}) {
    if (!_hasAuthority() || duration <= Duration.zero) return;
    final authority = _epoch;
    late Timer timer;
    timer = Timer(duration, () {
      _timers.remove(timer);
      if (!_retired && authority == _epoch && _hasAuthority()) {
        onElapsed();
      }
      if (!_retired) notifyListeners();
    });
    _timers.add(timer);
    notifyListeners();
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    busy = false;
    failure = CookingSessionFailure.staleAuthority;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}
