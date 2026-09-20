import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/cooking_assistant/data/cooking_timers_controller.dart';
import 'package:larenor/features/cooking_assistant/domain/cooking_timer.dart';

final class _Clock implements CookingTimerClock {
  _Clock({required this.wall, required this.monotonic});
  Duration wall;
  Duration monotonic;
  @override
  Duration get wallNow => wall;
  @override
  Duration get monotonicNow => monotonic;
}

final class _Store implements CookingTimerStore {
  final Map<String, CookingTimer> records = {};
  @override
  Future<List<CookingTimer>> read(String accountId, String recipeSessionId) async =>
      records.values
          .where((value) =>
              value.accountId == accountId &&
              value.recipeSessionId == recipeSessionId)
          .toList();
  @override
  Future<void> write(CookingTimer timer, {required int expectedRevision}) async {
    final old = records[timer.id];
    if ((old?.revision ?? 0) != expectedRevision) throw StateError('revision');
    records[timer.id] = timer;
  }
}

final class _Notifications implements CookingTimerNotifications {
  final Set<String> delivered = {};
  @override
  Future<void> finished({
    required String idempotencyKey,
    required String label,
  }) async => delivered.add(idempotencyKey);
}

void main() {
  test('multiple timers use monotonic time and restore exact deadlines', () async {
    final store = _Store();
    final clock = _Clock(
      wall: const Duration(hours: 100),
      monotonic: const Duration(hours: 5),
    );
    final authority = CookingTimerAuthority(
      accountId: 'account-a', recipeSessionId: 'recipe-session', epoch: 4);
    final controller = CookingTimersController(
      store: store,
      notifications: _Notifications(),
      clock: clock,
      authority: authority,
      isCurrent: () => true,
    );
    await controller.restore();
    await controller.start(label: 'Oven', duration: const Duration(minutes: 10));
    await controller.start(label: 'Sauce', duration: const Duration(minutes: 3));
    clock.wall += const Duration(days: 2); // wall clock edits do not affect this run
    clock.monotonic += const Duration(minutes: 2);

    expect(controller.remaining(controller.timers[0]), const Duration(minutes: 8));
    expect(controller.remaining(controller.timers[1]), const Duration(minutes: 1));

    final restartedClock = _Clock(
      wall: const Duration(hours: 100, minutes: 4),
      monotonic: const Duration(seconds: 2),
    );
    final restored = CookingTimersController(
      store: store,
      notifications: _Notifications(),
      clock: restartedClock,
      authority: authority,
      isCurrent: () => true,
    );
    await restored.restore();
    expect(restored.remaining(restored.timers[0]), const Duration(minutes: 6));
    expect(restored.remaining(restored.timers[1]), Duration.zero);
  });

  test('finish notification and acknowledge are idempotent', () async {
    final store = _Store();
    final notifications = _Notifications();
    final clock = _Clock(wall: Duration.zero, monotonic: Duration.zero);
    final authority = CookingTimerAuthority(
      accountId: 'account-a', recipeSessionId: 'recipe-session', epoch: 1);
    final controller = CookingTimersController(
      store: store,
      notifications: notifications,
      clock: clock,
      authority: authority,
      isCurrent: () => true,
    );
    await controller.restore();
    await controller.start(label: 'Tea', duration: const Duration(seconds: 1));
    clock.monotonic += const Duration(seconds: 2);
    await controller.resume();
    await controller.resume();
    expect(notifications.delivered, hasLength(1));
    expect(await controller.acknowledge(controller.timers.single.id), isTrue);
    expect(await controller.acknowledge(controller.timers.single.id), isTrue);
    expect(controller.timers.single.acknowledged, isTrue);
  });

  test('authority change rejects late restore, timer mutation and notification', () async {
    var current = true;
    final store = _Store();
    final notifications = _Notifications();
    final clock = _Clock(wall: Duration.zero, monotonic: Duration.zero);
    final controller = CookingTimersController(
      store: store,
      notifications: notifications,
      clock: clock,
      authority: const CookingTimerAuthority(
        accountId: 'account-a', recipeSessionId: 'recipe-session', epoch: 1),
      isCurrent: () => current,
    );
    await controller.restore();
    await controller.start(label: 'Tea', duration: const Duration(seconds: 1));
    current = false;
    clock.monotonic += const Duration(seconds: 2);
    await controller.resume();
    expect(await controller.acknowledge(controller.timers.single.id), isFalse);
    expect(notifications.delivered, isEmpty);
    expect(controller.failure, CookingTimerFailure.staleAuthority);
  });
}
