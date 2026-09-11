import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
    'round trip restores an explicitly retained and non-writable snapshot',
    () async {
      final backend = _Backend();
      final store = TodayRetainedStore(backend: backend);
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
    final store = TodayRetainedStore(backend: backend);
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

  test(
    'retired read cannot publish data after route or account disposal',
    () async {
      final backend = _Backend();
      final store = TodayRetainedStore(backend: backend);
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
