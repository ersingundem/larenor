import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_storage.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'prepared_restore_test.dart' as fixtures;

class _Platform extends InMemorySharedPreferencesStore {
  _Platform() : super.withData({'flutter.appearance': 'dark'});
  bool reject = false, throwing = false, readFailure = false;
  int writes = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes++;
    if (throwing) throw StateError('private-platform-details');
    if (reject) return false;
    return super.setValue(type, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    if (readFailure) throw StateError('private-platform-details');
    return super.getAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  for (final throwing in [false, true]) {
    test(
      'durable preview rejects false optimistic cached value throwing=$throwing',
      () async {
        final platform = _Platform();
        SharedPreferencesStorePlatform.instance = platform;
        final prefs = await SharedPreferences.getInstance();
        platform.reject = true;
        platform.throwing = throwing;
        try {
          await prefs.setString('appearance', 'system');
        } catch (_) {}
        expect(
          prefs.get('appearance'),
          'system',
        ); // Actual legacy optimistic cache.
        platform.reject = false;
        platform.throwing = false;
        final repo = BackupRepository(storage: PlatformBackupStorage());
        final prepared = await fixtures.prepare(
          repo,
          fixtures.TestRestoreAccess(),
        );
        // This is already the durable value observed by correct preparation.
        await platform.setValue('String', 'flutter.appearance', 'dark');
        await prefs.reload();
        await fixtures.apply(prepared);
        expect((await platform.getAll())['flutter.appearance'], 'light');
      },
    );
  }
  test('external durable target change is observed before journal write despite cached old value', () async {
    final platform = _Platform();
    SharedPreferencesStorePlatform.instance = platform;
    final prefs = await SharedPreferences.getInstance();
    final prepared = await fixtures.prepare(
      BackupRepository(storage: PlatformBackupStorage()),
      fixtures.TestRestoreAccess(),
    );
    await platform.setValue('String', 'flutter.appearance', 'system');
    expect(prefs.get('appearance'), 'dark');
    final baseline = platform.writes;
    await expectLater(
      fixtures.apply(prepared),
      throwsA(isA<BackupException>()),
    );
    expect(platform.writes, baseline);
    expect((await platform.getAll())['flutter.appearance'], 'system');
    expect(
      await const FlutterSecureStorage().read(key: 'backup_restore_journal_v2'),
      isNull,
    );
  });
  test(
    'platform read failure is static and never an empty successful target',
    () async {
      final platform = _Platform();
      SharedPreferencesStorePlatform.instance = platform;
      await SharedPreferences.getInstance();
      platform.readFailure = true;
      await expectLater(
        fixtures.prepare(
          BackupRepository(storage: PlatformBackupStorage()),
          fixtures.TestRestoreAccess(),
        ),
        throwsA(isA<BackupException>()),
      );
      expect(platform.writes, 0);
    },
  );
}
