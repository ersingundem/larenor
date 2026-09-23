import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/local_notifications/data/local_notification_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class MemoryBackend implements LocalNotificationStoreBackend {
  final values = <String, String>{};
  Future<void> Function()? afterRead;
  Future<void> Function()? afterWrite;
  int reads = 0, writes = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    final value = values[key];
    await afterRead?.call();
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
    await afterWrite?.call();
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

ServerContext context() => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});

void main() {
  test(
    'registration record is scope bound CAS protected and lifecycle guarded',
    () async {
      final backend = MemoryBackend(),
          store = LocalNotificationStore(backend: backend);
      final record = LocalNotificationStore.create(
        context(),
        'c' * 32,
        DateTime.utc(2026, 9, 20),
      );
      await store.write(record, before: null, isCurrent: () => true);
      expect(
        await store.read(context(), 'c' * 32, isCurrent: () => true),
        isA<LocalNotificationStoredSubscription>().having(
          (v) => v.id,
          'id',
          record.id,
        ),
      );
      await expectLater(
        store.write(record, before: null, isCurrent: () => true),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'revision_conflict',
          ),
        ),
      );
      var current = true;
      backend.afterRead = () async => current = false;
      await expectLater(
        store.read(context(), 'c' * 32, isCurrent: () => current),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
  );

  test(
    'throwing authority callback cancels before secure storage read',
    () async {
      final backend = MemoryBackend();
      final store = LocalNotificationStore(backend: backend);

      await expectLater(
        store.read(
          context(),
          'c' * 32,
          isCurrent: () => throw StateError('retired authority'),
        ),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(backend.reads, 0);
    },
  );

  test(
    'authority drift during secure write restores the previous record',
    () async {
      final backend = MemoryBackend();
      final store = LocalNotificationStore(backend: backend);
      final before = LocalNotificationStore.create(
        context(),
        'c' * 32,
        DateTime.utc(2026, 9, 20),
      );
      await store.write(before, before: null, isCurrent: () => true);
      final storageKey = LocalNotificationStore.key(context(), 'c' * 32);
      final previous = backend.values[storageKey];
      final record = LocalNotificationStoredSubscription(
        context: before.context,
        actorId: before.actorId,
        id: before.id,
        revision: 1,
        expiresAt: before.expiresAt.add(const Duration(days: 1)),
      );
      var current = true;
      backend.afterWrite = () async => current = false;

      await expectLater(
        store.write(record, before: before, isCurrent: () => current),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(backend.values[storageKey], previous);
    },
  );

  test('CAS rejects a before record owned by another authority', () async {
    final backend = MemoryBackend();
    final store = LocalNotificationStore(backend: backend);
    final before = LocalNotificationStore.create(
      context(),
      'c' * 32,
      DateTime.utc(2026, 9, 20),
    );
    await store.write(before, before: null, isCurrent: () => true);
    final replacement = LocalNotificationStoredSubscription(
      context: before.context,
      actorId: before.actorId,
      id: before.id,
      revision: before.revision + 1,
      expiresAt: before.expiresAt,
    );
    final wrongAuthority = LocalNotificationStoredSubscription(
      context: ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': 'd' * 32,
        'homeId': 'e' * 32,
      }),
      actorId: 'f' * 32,
      id: before.id,
      revision: before.revision,
      expiresAt: before.expiresAt,
    );

    await expectLater(
      store.write(replacement, before: wrongAuthority, isCurrent: () => true),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'revision_conflict',
        ),
      ),
    );
  });
}
