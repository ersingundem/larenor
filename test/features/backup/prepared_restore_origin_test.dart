import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';

import 'backup_test_storage.dart';
import 'prepared_restore_test.dart' as f;

const _url = 'ha_base_url', _token = 'ha_token';

class _Storage extends MemoryBackupStorage {
  _Storage()
    : super(
        secrets: {_url: 'http://source-a.test', _token: 'synthetic-a'},
        preferences: {'enabled_services': <String>[]},
      );
  void Function(String)? didWrite;
  @override
  Future<void> writeSecret(String key, String? value) async {
    await super.writeSecret(key, value);
    didWrite?.call(key);
  }
}

BackupSnapshot _home() => f.restoreFixture({
  'enabled_services': <String>['sonarr'],
});
BackupSnapshot _connection() => BackupSnapshot.fromJson({
  'version': 1,
  'createdAt': '2026-09-06T00:00:00Z',
  'groups': {
    'connections': {
      'ha': {
        'baseUrl': 'http://approved-new.test',
        'token': 'approved-synthetic-token',
      },
    },
  },
});
Future<PreparedBackupRestore> _prepareConnection(_Storage storage) =>
    BackupRepository(storage: storage).prepareRestore(
      _connection(),
      const BackupSelection(
        settings: false,
        dashboard: false,
        connections: true,
      ),
      conflictPolicy: BackupConflictPolicy.replaceSelected,
      access: f.TestRestoreAccess(),
    );
void main() {
  test(
    'Direct home preview A cannot apply under later HA B with unchanged target',
    () async {
      final storage = _Storage();
      final prepared = await f.prepare(
        BackupRepository(storage: storage),
        f.TestRestoreAccess(),
        _home(),
      );
      storage.secrets
        ..[_url] = 'http://source-b.test'
        ..[_token] = 'synthetic-b';
      await expectLater(f.apply(prepared), throwsA(isA<BackupException>()));
      expect(storage.writes, isEmpty);
      expect(storage.preferences['enabled_services'], isEmpty);
    },
  );
  test('pending HA origin blocks home-bearing settings while no connection group selected', () async {
    final storage = _Storage()
      ..secrets[CredentialsStore.pendingMutationKey] = '1';
    await expectLater(
      f.prepare(
        BackupRepository(storage: storage),
        f.TestRestoreAccess(),
        _home(),
      ),
      throwsA(isA<BackupException>()),
    );
    expect(storage.writes, isEmpty);
  });
  test(
    'late pending origin blocks a previously prepared home target',
    () async {
      final storage = _Storage();
      final prepared = await f.prepare(
        BackupRepository(storage: storage),
        f.TestRestoreAccess(),
        _home(),
      );
      storage.secrets[CredentialsStore.pendingMutationKey] = '1';
      await expectLater(f.apply(prepared), throwsA(isA<BackupException>()));
      expect(storage.writes, isEmpty);
    },
  );
  for (final source in HomeSource.values) {
    test(
      'pure device target under $source never reads Direct origin',
      () async {
        final storage = _Storage()
          ..secrets[CredentialsStore.pendingMutationKey] = '1';
        if (source == HomeSource.verifiedCore) {
          storage.preferences[SharedPreferencesHomeSourceStore.key] =
              source.name;
          storage.secrets['larenor_server_session_v1'] = f
              .coreSession()
              .encodeStorage();
        }
        await f.apply(
          await f.prepare(
            BackupRepository(storage: storage),
            f.TestRestoreAccess()..source = source,
          ),
        );
        expect(
          storage.reads.where(
            (key) => {
              _url,
              _token,
              CredentialsStore.pendingMutationKey,
            }.any((secret) => key == 'secret:$secret'),
          ),
          isEmpty,
        );
        expect(storage.preferences['appearance'], 'light');
      },
    );
  }
  test(
    'approved HA restore advances only its exact frozen field sequence',
    () async {
      final storage = _Storage();
      await f.apply(await _prepareConnection(storage));
      expect(storage.secrets, {
        _url: 'http://approved-new.test',
        _token: 'approved-synthetic-token',
        'wellbeing_disclosure_policy_v1':
            '{"version":1,"entityIds":[],"reviewRequired":true}',
      });
      expect(
        storage.writes.where(
          (v) => v == 'secret:$_url' || v == 'secret:$_token',
        ),
        ['secret:$_url', 'secret:$_token'],
      );
    },
  );
  test('third HA tuple during own approved write is preserved and stops remaining effects', () async {
    final storage = _Storage();
    final prepared = await _prepareConnection(storage);
    storage.didWrite = (key) {
      if (key == _url) storage.secrets[_token] = 'third-party-token';
    };
    await expectLater(f.apply(prepared), throwsA(isA<BackupException>()));
    expect(storage.secrets[_token], 'third-party-token');
    expect(storage.writes, isNot(contains('secret:$_token')));
    expect(storage.secrets, contains('backup_restore_journal_v2'));
  });
}
