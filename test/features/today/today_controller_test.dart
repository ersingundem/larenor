import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/today/data/today_controller.dart';
import 'package:larenor/features/today/data/today_repository.dart';
import 'package:larenor/features/today/domain/today_models.dart';

import 'fake_today_api.dart';

void main() {
  late FakeTodayApi api;
  late TodayController controller;
  setUp(() {
    api = FakeTodayApi();
    controller = TodayController(
      repository: TodayRepository(
        api: api,
        now: () => DateTime.utc(2026, 9, 5),
      ),
    );
  });
  tearDown(() => controller.dispose());

  test('local read is distinct from server dismissal and revised content becomes unread', () async {
    await controller.refresh();
    controller.markNotificationRead('notice');
    expect(controller.snapshot!.notifications.value!.single.isRead, isTrue);
    expect(api.serviceCalls, isEmpty);
    await controller.refresh();
    expect(controller.snapshot!.notifications.value!.single.isRead, isTrue);
    api.notifications = [notification(createdAt: '2026-09-05T11:00:00Z')];
    await controller.refresh();
    expect(controller.snapshot!.notifications.value!.single.isRead, isFalse);
    expect(api.serviceCalls, isEmpty);
  });

  test('read bursts coalesce and post-action invalidation requests one trailing read', () async {
    final release = Completer<void>();
    api.beforeConfig = () => release.future;
    final first = controller.refresh();
    final second = controller.refresh();
    controller.refresh(afterCurrent: true);
    controller.refresh(afterCurrent: true);
    expect(identical(first, second), isTrue);
    expect(api.configCalls, 1);
    release.complete();
    await first;
    await drain();
    expect(api.configCalls, 2);
    expect(api.serviceCalls, isEmpty);
  });

  test(
    'subscription event during older snapshot load is not overwritten',
    () async {
      controller.setConnected(true);
      final release = Completer<void>();
      api.beforeConfig = () => release.future;
      final load = controller.refresh();
      await drain();
      api.subscriptions.single.add({
        'type': 'current',
        'notifications': {'new': notification(id: 'new')},
      });
      await drain();
      release.complete();
      await load;
      expect(controller.snapshot!.notifications.value!.single.id, 'new');
    },
  );

  test('correct added/updated/removed events and malformed delta preserve other sources', () async {
    controller.setConnected(true);
    await controller.refresh();
    await drain();
    api.subscriptions.single.add({
      'type': 'added',
      'notifications': {'two': notification(id: 'two')},
    });
    await drain();
    expect(controller.snapshot!.notifications.value, hasLength(2));
    api.subscriptions.single.add({
      'type': 'removed',
      'notifications': {'notice': notification()},
    });
    await drain();
    expect(controller.snapshot!.notifications.value!.single.id, 'two');
    api.subscriptions.single.add({
      'type': 'added',
      'notifications': {'wrong-id': notification(id: 'bad')},
    });
    await drain();
    expect(controller.snapshot!.notifications.isStale, isTrue);
    expect(controller.snapshot!.notifications.value!.single.id, 'two');
    expect(controller.snapshot!.todoLists.single.items.value, hasLength(1));
    api.subscriptions.single.add({'type': 'current', 'notifications': {}});
    await drain();
    expect(controller.snapshot!.notifications.value, isEmpty);
    expect(controller.snapshot!.notifications.issue, isNull);
  });

  test('foreground and connection lifetimes cancel and renew subscriptions without mutations', () async {
    controller.setConnected(true);
    await controller.refresh();
    await drain();
    expect(api.subscriptions, hasLength(1));
    controller.setForeground(false);
    await controller.refresh();
    await drain();
    expect(api.cancelled, 1);
    expect(api.configCalls, 1);
    controller.setForeground(true);
    await controller.refresh();
    await drain();
    expect(api.subscriptions, hasLength(2));
    controller.setConnected(false);
    await drain();
    expect(api.cancelled, 2);
    controller.setConnected(true);
    await drain();
    expect(api.subscriptions, hasLength(3));
    expect(api.serviceCalls, isEmpty);
  });

  test('disposed controller ignores late read data and never carries local reads to another account', () async {
    await controller.refresh();
    controller.markNotificationRead('notice');
    final before = controller.snapshot;
    final gate = Completer<void>();
    api.beforeConfig = () => gate.future;
    final pending = controller.refresh();
    controller.dispose();
    gate.complete();
    await pending;
    expect(identical(controller.snapshot, before), isTrue);
    final other = TodayController(
      repository: TodayRepository(api: FakeTodayApi()),
    );
    addTearDown(other.dispose);
    await other.refresh();
    expect(other.snapshot!.notifications.value!.single.isRead, isFalse);
  });

  test(
    'unknown baseline cannot be declared complete by a partial added event',
    () async {
      api.notificationsError = const TodayException('fixture');
      controller.setConnected(true);
      await controller.refresh();
      await drain();
      api.subscriptions.single.add({
        'type': 'added',
        'notifications': {'new': notification(id: 'new')},
      });
      await drain();
      expect(controller.snapshot!.notifications.value, isNull);
      expect(controller.snapshot!.notifications.issue, isNotNull);
      api.subscriptions.single.add({'type': 'current', 'notifications': {}});
      await drain();
      expect(controller.snapshot!.notifications.value, isEmpty);
    },
  );

  test(
    'unexpected whole-read failure labels all retained data stale',
    () async {
      await controller.refresh();
      final before = controller.snapshot!;
      controller.repository.dispose();
      await controller.refresh();
      final current = controller.snapshot!;
      expect(current.todoLists.single.items.isStale, isTrue);
      expect(current.todoLists.single.canUpdate, isFalse);
      expect(current.calendars.single.events.isStale, isTrue);
      expect(current.notifications.isStale, isTrue);
      expect(current.notifications.readAt, before.notifications.readAt);
      expect(
        current.todoLists.single.items.value,
        before.todoLists.single.items.value,
      );
    },
  );
}
