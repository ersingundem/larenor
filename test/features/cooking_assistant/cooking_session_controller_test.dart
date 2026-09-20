import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/cooking_assistant/data/cooking_session_controller.dart';
import 'package:oikos/features/cooking_assistant/domain/cooking_session.dart';

final class _Gateway implements CookingSessionGateway {
  _Gateway(this.value);
  CookingSession value;
  final Completer<CookingSession> pending = Completer<CookingSession>();
  bool delay = false;
  int moves = 0;

  @override
  Future<CookingSession> move({
    required String sessionId,
    required int expectedRevision,
    required int step,
  }) async {
    moves++;
    if (delay) return pending.future;
    value = value.copyWith(currentStep: step, revision: expectedRevision + 1);
    return value;
  }
}

CookingSession session({int step = 0, int revision = 1}) => CookingSession(
  id: 'session-1',
  accountId: 'account-a',
  recipeId: 'recipe-1',
  recipeRevision: 8,
  revision: revision,
  title: 'Soup',
  steps: const ['Prepare', 'Cook', 'Rest'],
  currentStep: step,
);

void main() {
  test('next and previous use exact revision and never cross bounds', () async {
    final gateway = _Gateway(session());
    final controller = CookingSessionController(
      gateway: gateway,
      initial: gateway.value,
      isCurrent: () => true,
    );

    expect(await controller.previous(), isFalse);
    expect(await controller.next(), isTrue);
    expect(controller.value.currentStep, 1);
    expect(controller.value.revision, 2);
    expect(await controller.previous(), isTrue);
    expect(controller.value.currentStep, 0);
  });

  test('late command is discarded after account authority changes', () async {
    var current = true;
    final gateway = _Gateway(session())..delay = true;
    final controller = CookingSessionController(
      gateway: gateway,
      initial: gateway.value,
      isCurrent: () => current,
    );
    final operation = controller.next();
    current = false;
    gateway.pending.complete(session(step: 1, revision: 2));

    expect(await operation, isFalse);
    expect(controller.value.currentStep, 0);
    expect(controller.failure, CookingSessionFailure.staleAuthority);
  });

  test('timer never fires after lifecycle retirement', () async {
    final fired = <String>[];
    final controller = CookingSessionController(
      gateway: _Gateway(session()),
      initial: session(),
      isCurrent: () => true,
    );
    controller.startTimer(
      const Duration(milliseconds: 10),
      onElapsed: () => fired.add('elapsed'),
    );
    controller.retire();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(fired, isEmpty);
    expect(controller.activeTimerCount, 0);
  });
}

