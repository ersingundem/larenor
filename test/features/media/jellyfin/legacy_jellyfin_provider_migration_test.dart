import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_provider_preview.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

import '../../server/server_services_test.dart';

const _legacy = {
  'jellyfin_base_url': 'https://private-jellyfin.invalid/root',
  'jellyfin_user_id': 'private-user-id',
  'jellyfin_access_token': 'private-access-token',
};

final class _Storage extends FlutterSecureStorage {
  _Storage([Map<String, String> values = const {}]) : values = Map.of(values);

  final Map<String, String> values;
  final calls = <(String, String)>[];
  int? failDeleteAt;
  int deletes = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add(('read', key));
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add(('write', key));
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add(('delete', key));
    if (deletes++ == failDeleteAt) {
      throw StateError('private-delete-failure');
    }
    values.remove(key);
  }
}

Map<String, dynamic> _service({
  required int revision,
  required String checkedAt,
}) => {
  ...serviceJson(revision: revision, state: 'authenticated'),
  'verification': {
    'state': 'authenticated',
    'checkedAt': checkedAt,
    'version': '10.11',
  },
};

void main() {
  test(
    'changed exact legacy source rejects before another Core read',
    () async {
      final storage = _Storage(_legacy);
      final fixture = ServicesFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final migration = LegacyJellyfinProviderMigration(
        account: fixture.account,
        storage: storage,
      );
      addTearDown(migration.dispose);
      final receipt = await migration.prepare(isCurrent: () => true);
      expect(receipt?.provider, LegacyMediaProvider.jellyfin);
      expect(receipt?.requiresCredentialReentry, isTrue);
      expect(receipt.toString(), 'Legacy media provider migration');
      storage.values['jellyfin_access_token'] = 'changed-private-token';
      final record = _service(
        revision: 1,
        checkedAt: '2026-09-23T09:30:00.000Z',
      );
      fixture.records.add(record);
      final readsBefore = fixture.calls
          .where((call) => call.url.path.endsWith('/admin/services'))
          .length;

      await expectLater(
        migration.confirm(
          receipt!,
          ServerService.fromJson(record),
          isCurrent: () => true,
        ),
        throwsStateError,
      );

      expect(
        fixture.calls
            .where((call) => call.url.path.endsWith('/admin/services'))
            .length,
        readsBefore,
      );
      expect(storage.values['jellyfin_access_token'], 'changed-private-token');
    },
  );

  test('requires post-preview authenticated Core revision then retires direct tuple', () async {
    final storage = _Storage(_legacy);
    final fixture = ServicesFixture()
      ..records.add(
        _service(revision: 1, checkedAt: '2026-09-23T09:00:00.000Z'),
      );
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final migration = LegacyJellyfinProviderMigration(
      account: fixture.account,
      storage: storage,
    );
    addTearDown(migration.dispose);
    final receipt = await migration.prepare(isCurrent: () => true);
    final unchanged = ServerService.fromJson(fixture.records.single);

    await expectLater(
      migration.confirm(receipt!, unchanged, isCurrent: () => true),
      throwsStateError,
    );
    expect(
      storage.values,
      containsPair('jellyfin_base_url', _legacy['jellyfin_base_url']),
    );

    fixture.records.single
      ..['revision'] = 2
      ..['verification'] = {
        'state': 'authenticated',
        'checkedAt': '2026-09-23T09:31:00.000Z',
        'version': '10.11',
      };
    final replacement = ServerService.fromJson(fixture.records.single);
    await migration.confirm(receipt, replacement, isCurrent: () => true);

    expect(
      storage.values.keys.where((key) => key.startsWith('jellyfin_')),
      isEmpty,
    );
    expect(fixture.mutations, isEmpty);
    final wire = fixture.calls
        .map((call) => '${call.url} ${call.body}')
        .join(' ');
    for (final secret in _legacy.values) {
      expect(wire, isNot(contains(secret)));
    }
  });

  test('uncertain direct retirement retries without a Core mutation or source read', () async {
    final storage = _Storage(_legacy)..failDeleteAt = 1;
    final fixture = ServicesFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final migration = LegacyJellyfinProviderMigration(
      account: fixture.account,
      storage: storage,
    );
    addTearDown(migration.dispose);
    final receipt = await migration.prepare(isCurrent: () => true);
    fixture.records.add(
      _service(revision: 1, checkedAt: '2026-09-23T09:31:00.000Z'),
    );
    final target = ServerService.fromJson(fixture.records.single);

    await expectLater(
      migration.confirm(receipt!, target, isCurrent: () => true),
      throwsA(
        isA<DirectHomeAccessException>().having(
          (error) => error.code,
          'code',
          'write_unconfirmed',
        ),
      ),
    );
    expect(
      storage.values['jellyfin_connection_pending_v1'],
      '1',
      reason: 'a partial clear must remain explicitly uncertain',
    );
    final readsAfterFailure = storage.calls
        .where((call) => call.$1 == 'read')
        .length;
    storage.failDeleteAt = null;

    await migration.confirm(receipt, target, isCurrent: () => true);

    expect(
      storage.calls.where((call) => call.$1 == 'read').length,
      readsAfterFailure,
      reason: 'retry must not treat a partial legacy tuple as a new preview',
    );
    expect(
      storage.values.keys.where((key) => key.startsWith('jellyfin_')),
      isEmpty,
    );
    expect(fixture.mutations, isEmpty);
    expect(
      fixture.calls.where((call) => call.url.path.endsWith('/admin/services')),
      hasLength(3),
    );
  });
}
