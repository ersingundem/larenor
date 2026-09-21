import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/local_notifications/data/local_notification_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class MemoryBackend implements LocalNotificationStoreBackend {
  final values = <String, String>{};
  Future<void> Function()? afterRead;
  @override
  Future<String?> read(String key) async {
    final value = values[key];
    await afterRead?.call();
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
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
}
