import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/today/data/today_retained_cache.dart';
import 'package:larenor/features/today/domain/today_models.dart';

final class _Backend implements TodayRetainedBackend {
  final values = <String, String>{};
  Completer<void>? readGate;

  @override
  Future<String?> read(String key) async {
    await readGate?.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

TodaySnapshot _snapshot(String title) => TodaySnapshot(
  configured: true,
  refreshedAt: DateTime.utc(2026, 9, 11, 8),
  timeZone: 'Europe/Istanbul',
  dayStart: DateTime.utc(2026, 9, 10, 21),
  dayEnd: DateTime.utc(2026, 9, 11, 21),
  todoLists: [
    TodayTodoList(
      entityId: 'todo.shopping',
      title: 'Shopping',
      supportedFeatures: 5,
      available: true,
      items: TodayRead(
        value: [
          TodayTodoItem(
            uid: 'one',
            summary: title,
            status: TodayTodoStatus.needsAction,
          ),
        ],
        readAt: DateTime.utc(2026, 9, 11, 8),
      ),
    ),
  ],
  notifications: const TodayRead(value: []),
);

void main() {
  const first = HaConnectionConfig(
    baseUrl: 'http://ha-one.invalid:8123',
    token: 'account-one-secret',
  );
  const secondAccount = HaConnectionConfig(
    baseUrl: 'http://ha-one.invalid:8123',
    token: 'account-two-secret',
  );

  test(
    'encrypted cache key is scoped to HA endpoint and account credential',
    () {
      final one = TodayRetainedScope.direct(first);
      final same = TodayRetainedScope.direct(first);
      final other = TodayRetainedScope.direct(secondAccount);

      expect(one.storageKey, same.storageKey);
      expect(one.storageKey, isNot(other.storageKey));
      expect(one.storageKey, isNot(contains(first.baseUrl)));
      expect(one.storageKey, isNot(contains(first.token)));
      expect(one.toString(), 'TodayRetainedScope');
    },
  );

  test(
    'Core cache identity changes with home and user without exposing IDs',
    () {
      HomeDataScope scope(String home, String user) => HomeDataScope.fromJson({
        'coreId': 'a' * 32,
        'homeId': home,
        'userId': user,
      });
      final firstScope = scope('b' * 32, 'member-one');
      final first = TodayRetainedScope.core(firstScope);
      final otherHome = TodayRetainedScope.core(scope('c' * 32, 'member-one'));
      final otherUser = TodayRetainedScope.core(scope('b' * 32, 'member-two'));

      expect(first.storageKey, isNot(otherHome.storageKey));
      expect(first.storageKey, isNot(otherUser.storageKey));
      expect(first.storageKey, isNot(contains(firstScope.coreId)));
      expect(first.storageKey, isNot(contains(firstScope.homeId)));
      expect(first.storageKey, isNot(contains(firstScope.userId)));
    },
  );

  test(
    'round trip restores an explicitly retained and non-writable snapshot',
    () async {
      final backend = _Backend();
      final store = TodayRetainedStore(
        backend: backend,
        clock: () => DateTime.utc(2026, 9, 11, 9),
      );
      final scope = TodayRetainedScope.direct(first);

      await store.write(scope, _snapshot('Milk'), isCurrent: () => true);
      final restored = await store.read(scope, isCurrent: () => true);

      expect(restored, isNotNull);
      expect(restored!.retained, isTrue);
      expect(restored.todoLists.single.items.isStale, isTrue);
      expect(restored.todoLists.single.items.value!.single.summary, 'Milk');
      expect(backend.values.values.single, isNot(contains(first.token)));
      expect(backend.values.values.single, isNot(contains(first.baseUrl)));
    },
  );

  test('wrong scope and corrupt or oversized records fail closed', () async {
    final backend = _Backend();
    final store = TodayRetainedStore(
      backend: backend,
      clock: () => DateTime.utc(2026, 9, 11, 9),
    );
    final firstScope = TodayRetainedScope.direct(first);
    final otherScope = TodayRetainedScope.direct(secondAccount);
    await store.write(firstScope, _snapshot('Milk'), isCurrent: () => true);

    expect(await store.read(otherScope, isCurrent: () => true), isNull);
    backend.values[otherScope.storageKey] = '{"token":"private-token"}';
    expect(await store.read(otherScope, isCurrent: () => true), isNull);
    expect(backend.values.containsKey(otherScope.storageKey), isFalse);
    backend.values[otherScope.storageKey] = 'x' * (256 * 1024 + 1);
    expect(await store.read(otherScope, isCurrent: () => true), isNull);
  });

  test('invalid timezone and incoherent calendar event fail closed', () async {
    final backend = _Backend();
    final store = TodayRetainedStore(
      backend: backend,
      clock: () => DateTime.utc(2026, 9, 11, 9),
    );
    final scope = TodayRetainedScope.direct(first);
    await store.write(scope, _snapshot('Milk'), isCurrent: () => true);
    final original = jsonDecode(backend.values.values.single) as Map;

    backend.values[scope.storageKey] = jsonEncode({
      ...original,
      'timeZone': 'Private/Unknown',
    });
    expect(await store.read(scope, isCurrent: () => true), isNull);

    final event = {
      'uid': 'event',
      'title': 'Broken',
      'start': '2026-09-11T08:00:00.000Z',
      'end': '2026-09-11T09:00:00.000Z',
      'allDay': true,
      'startDate': null,
      'endDate': null,
      'description': null,
      'location': null,
    };
    backend.values[scope.storageKey] = jsonEncode({
      ...original,
      'calendars': [
        {
          'entityId': 'calendar.family',
          'title': 'Family',
          'events': {
            'value': [event],
            'issue': null,
            'readAt': null,
          },
        },
      ],
    });
    expect(await store.read(scope, isCurrent: () => true), isNull);
    expect(backend.values, isEmpty);
  });

  test(
    'a retained summary never crosses the Home Assistant day boundary',
    () async {
      final backend = _Backend();
      final store = TodayRetainedStore(
        backend: backend,
        clock: () => DateTime.utc(2026, 9, 11, 22),
      );
      final scope = TodayRetainedScope.direct(first);
      await store.write(scope, _snapshot('Yesterday'), isCurrent: () => true);

      expect(await store.read(scope, isCurrent: () => true), isNull);
      expect(backend.values, isEmpty);
    },
  );

  test(
    'retired read cannot publish data after route or account disposal',
    () async {
      final backend = _Backend();
      final store = TodayRetainedStore(
        backend: backend,
        clock: () => DateTime.utc(2026, 9, 11, 9),
      );
      final scope = TodayRetainedScope.direct(first);
      await store.write(scope, _snapshot('Milk'), isCurrent: () => true);
      backend.readGate = Completer<void>();
      var current = true;

      final pending = store.read(scope, isCurrent: () => current);
      current = false;
      backend.readGate!.complete();

      await expectLater(
        pending,
        throwsA(
          isA<TodayRetainedException>().having(
            (error) => error.code,
            'code',
            'retired',
          ),
        ),
      );
    },
  );
}
