import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Uses the pinned plugin's public platform test seam.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_credential_record.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/backup/data/backup_storage.dart';
import 'package:larenor/features/media/arr/data/arr_credentials_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/direct_home_boundary_test.dart' as auth_fixture;
import 'backup_test_storage.dart';

const _connections = BackupSelection(
  settings: false,
  dashboard: false,
  connections: true,
);
const _local = BackupSelection();
final _markers = {
  CredentialsStore.pendingMutationKey,
  ...DirectCredentialService.values.map((s) => s.pendingMutationKey),
};

Map<String, String> _record(String service) => {
  for (final field in backupConnectionFields[service]!.keys)
    field: switch (field) {
      'baseUrl' => 'https://new.example.test',
      'host' => 'new.example.test',
      'port' => '8006',
      'allowSelfSigned' => 'false',
      _ => 'synthetic-new-value',
    },
};
Map<String, String> _old(String service) => {
  for (final field in backupConnectionFields[service]!.entries)
    field.value: field.key == 'baseUrl'
        ? 'https://old.example.test'
        : _record(service)[field.key]!,
};
BackupSnapshot _snapshot(String? service) => BackupSnapshot.fromJson({
  'version': 1,
  'createdAt': '2026-09-06T00:00:00.000Z',
  'groups': {
    'settings': {'appearance': 'dark'},
    'dashboard': {
      'rooms': [],
      'tiles': [],
      'favoriteEntityIds': [],
      'hiddenEntityIds': [],
    },
    if (service != null) 'connections': {service: _record(service)},
  },
});
Matcher get _pending => throwsA(
  isA<BackupException>()
      .having((e) => e.code, 'static code', 'connection_pending')
      .having(
        (e) => e.toString(),
        'static message',
        'Complete the service connection again before backing up or restoring connections.',
      ),
);

class _Storage extends MemoryBackupStorage {
  _Storage({super.preferences, super.secrets});
  final Set<String> failedMarkers = {};
  Future<void> Function(String)? afterRead;
  Future<void> Function(String)? afterWrite;
  @override
  Future<String?> readSecret(String key) async {
    if (failedMarkers.contains(key)) {
      throw StateError('synthetic private payload');
    }
    final value = await super.readSecret(key);
    await afterRead?.call(key);
    return value;
  }

  @override
  Future<Object?> readPreference(String key) async {
    final value = await super.readPreference(key);
    await afterRead?.call(key);
    return value;
  }

  @override
  Future<void> writeSecret(String key, String? value) async {
    await super.writeSecret(key, value);
    await afterWrite?.call(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final service in DirectCredentialService.values) {
    final marker = service.pendingMutationKey;
    for (final value in ['1', '', 'false', 'unrecognized-private-marker']) {
      test(
        '${service.name} non-null marker length ${value.length} blocks capture before credential reads',
        () async {
          final storage = _Storage(
            secrets: {..._old(service.name), marker: value},
          );
          await expectLater(
            BackupRepository(storage: storage).capture(_connections),
            _pending,
          );
          for (final key in backupConnectionFields[service.name]!.values) {
            expect(storage.reads, isNot(contains('secret:$key')));
          }
          expect(storage.writes, isEmpty);
          expect(storage.secrets[marker], value);
        },
      );
    }
    for (final operation in ['preview', 'keep', 'replace']) {
      test(
        '${service.name} $operation rejects its pending marker or marker read failure',
        () async {
          for (final readFailure in [false, true]) {
            final storage = _Storage(
              secrets: {..._old(service.name), marker: '1'},
            );
            if (readFailure) storage.failedMarkers.add(marker);
            final repository = BackupRepository(storage: storage);
            await expectLater(
              operation == 'preview'
                  ? repository.preview(_snapshot(service.name))
                  : repository.restore(
                      _snapshot(service.name),
                      _connections,
                      conflictPolicy: operation == 'keep'
                          ? BackupConflictPolicy.keepExisting
                          : BackupConflictPolicy.replaceSelected,
                    ),
              _pending,
            );
            expect(storage.writes, isEmpty);
            expect(storage.secrets[marker], '1');
          }
        },
      );
    }
    test(
      '${service.name} marker is neither export schema nor rollback authority',
      () async {
        expect(backupPreferenceKeys, isNot(contains(marker)));
        expect(
          backupConnectionFields.values.expand((fields) => fields.values),
          isNot(contains(marker)),
        );
        final storage = _Storage(
          secrets: {
            marker: '1',
            BackupRepository.restoreJournalKey: jsonEncode({
              'version': 1,
              'changes': [
                {'secret': true, 'key': marker, 'before': null},
              ],
            }),
          },
        );
        await expectLater(
          BackupRepository(storage: storage).recoverPendingRestore(),
          throwsA(isA<BackupException>()),
        );
        expect(storage.writes, isEmpty);
        expect(storage.secrets[marker], '1');
        expect(
          () => BackupSnapshot.fromJson({
            'version': 1,
            'createdAt': '2026-09-06T00:00:00.000Z',
            'groups': {
              'connections': {
                service.name: {..._record(service.name), marker: '1'},
              },
            },
          }),
          throwsA(isA<BackupValidationException>()),
        );
      },
    );
  }

  test('unrelated Sonarr and HA pending markers cannot block Radarr preview or restore', () async {
    final pending = {
      DirectCredentialService.sonarr.pendingMutationKey: '1',
      CredentialsStore.pendingMutationKey: '1',
    };
    final storage = _Storage(secrets: {...pending, ..._old('radarr')})
      ..failedMarkers.addAll(pending.keys);
    final repository = BackupRepository(storage: storage);
    expect((await repository.preview(_snapshot('radarr'))).existingServices, [
      'radarr',
    ]);
    await repository.restore(
      _snapshot('radarr'),
      _connections,
      conflictPolicy: BackupConflictPolicy.replaceSelected,
    );
    expect(storage.secrets['radarr_base_url'], _record('radarr')['baseUrl']);
    for (final key in pending.keys) {
      expect(storage.secrets[key], '1');
      expect(storage.reads, isNot(contains('secret:$key')));
      expect(storage.writes, isNot(contains('secret:$key')));
    }
    storage.failedMarkers.remove(CredentialsStore.pendingMutationKey);
    storage.secrets.remove(CredentialsStore.pendingMutationKey);
    await expectLater(repository.capture(_connections), _pending);
  });

  test('settings dashboard and deselected connection restore never inspect markers', () async {
    final storage = _Storage(
      secrets: {for (final key in _markers) key: '1'},
      preferences: {'appearance': 'light'},
    )..failedMarkers.addAll(_markers);
    final repository = BackupRepository(storage: storage);
    final capture = await repository.capture(_local);
    expect(capture.hasConnections, isFalse);
    expect((await repository.preview(_snapshot(null))).hasConnections, isFalse);
    await repository.restore(
      _snapshot('sonarr'),
      _local,
      conflictPolicy: BackupConflictPolicy.replaceSelected,
    );
    expect(storage.preferences['appearance'], 'dark');
    for (final key in _markers) {
      expect(storage.reads, isNot(contains('secret:$key')));
      expect(storage.writes, isNot(contains('secret:$key')));
      expect(jsonEncode(capture.toJson()), isNot(contains(key)));
    }
  });

  for (final operation in ['capture', 'preview', 'prejournal']) {
    test(
      '$operation rejects a marker appearing after its initial guard',
      () async {
        final marker = DirectCredentialService.sonarr.pendingMutationKey;
        final storage = _Storage(secrets: _old('sonarr'));
        storage.afterRead = (key) async {
          if (key ==
              (operation == 'preview'
                  ? 'dashboard_layout'
                  : 'sonarr_api_key')) {
            storage.secrets[marker] = '1';
          }
        };
        final repository = BackupRepository(storage: storage);
        await expectLater(switch (operation) {
          'capture' => repository.capture(_connections),
          'preview' => repository.preview(_snapshot('sonarr')),
          _ => repository.restore(
            _snapshot('sonarr'),
            _connections,
            conflictPolicy: BackupConflictPolicy.replaceSelected,
          ),
        }, _pending);
        expect(storage.writes, isEmpty);
        expect(
          storage.secrets['sonarr_base_url'],
          _old('sonarr')['sonarr_base_url'],
        );
      },
    );
  }

  for (final stage in [
    BackupRepository.restoreJournalKey,
    'sonarr_base_url',
    'sonarr_api_key',
  ]) {
    test(
      'late marker at $stage rolls back durably without resetting marker',
      () async {
        final marker = DirectCredentialService.sonarr.pendingMutationKey;
        final storage = _Storage(secrets: _old('sonarr'));
        storage.afterWrite = (key) async {
          if (key == stage) storage.secrets[marker] = '1';
        };
        await expectLater(
          BackupRepository(storage: storage).restore(
            _snapshot('sonarr'),
            _connections,
            conflictPolicy: BackupConflictPolicy.replaceSelected,
          ),
          _pending,
        );
        expect(storage.secrets, {..._old('sonarr'), marker: '1'});
        expect(storage.writes, isNot(contains('secret:$marker')));
        for (final image in storage.durableImages) {
          final journal = image.secrets[BackupRepository.restoreJournalKey];
          if (journal != null) expect(journal, isNot(contains(marker)));
        }
      },
    );
  }

  test('failed rollback retains journal and recovery does not read any service marker', () async {
    final marker = DirectCredentialService.sonarr.pendingMutationKey;
    final storage = _Storage(secrets: _old('sonarr'))..failWrites.add(5);
    storage.afterWrite = (key) async {
      if (key == 'sonarr_api_key') storage.secrets[marker] = '1';
    };
    final repository = BackupRepository(storage: storage);
    await expectLater(
      repository.restore(
        _snapshot('sonarr'),
        _connections,
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      ),
      throwsA(
        isA<BackupRestoreException>().having(
          (e) => e.rollbackComplete,
          'rollback',
          isFalse,
        ),
      ),
    );
    expect(storage.secrets, contains(BackupRepository.restoreJournalKey));
    storage.failWrites.clear();
    storage.failedMarkers.addAll(_markers);
    final beforeReads = storage.reads.length;
    expect(await repository.recoverPendingRestore(), isTrue);
    expect(storage.secrets, {..._old('sonarr'), marker: '1'});
    expect(storage.reads.skip(beforeReads), [
      'secret:${BackupRepository.restoreJournalKey}',
      'secret:backup_restore_journal_v2',
    ]);
    expect(await repository.recoverPendingRestore(), isFalse);
    expect(storage.writes, isNot(contains('secret:$marker')));
  });

  test(
    'capture waits for a serialized Direct write before marker inspection',
    () async {
      final marker = DirectCredentialService.sonarr.pendingMutationKey;
      final storage = _Storage(secrets: _old('sonarr'));
      final started = Completer<void>();
      final release = Completer<void>();
      final mutation = ConfigurationWrites.run(() async {
        started.complete();
        await release.future;
        await storage.writeSecret(marker, '1');
      });
      await started.future;
      final rejected = expectLater(
        BackupRepository(storage: storage).capture(_connections),
        _pending,
      );
      expect(storage.reads, isEmpty);
      release.complete();
      await mutation;
      await rejected;
    },
  );

  for (final service in ['sonarr', 'radarr', 'lidarr', 'readarr']) {
    for (final recovery in ['save', 'clear']) {
      test(
        'real $service partial URL write blocks backup until explicit $recovery',
        () async {
          SharedPreferences.setMockInitialValues({});
          final secure = auth_fixture.SecurePlatform();
          final old = {
            '${service}_base_url': 'https://old.example.test',
            '${service}_api_key': 'synthetic-old-api-key',
          };
          secure.values
            ..clear()
            ..addAll(old);
          const channel = MethodChannel(
            'plugins.it_nomads.com/flutter_secure_storage',
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final previous = FlutterSecureStoragePlatform.instance;
          FlutterSecureStoragePlatform.instance =
              MethodChannelFlutterSecureStorage();
          var failUrlWrite = true;
          messenger.setMockMethodCallHandler(channel, (call) async {
            final result = await secure.handle(call);
            if (failUrlWrite &&
                call.method == 'write' &&
                (call.arguments as Map)['key'] == '${service}_base_url') {
              throw PlatformException(
                code: 'synthetic',
                message: 'synthetic private detail',
              );
            }
            return result;
          });
          addTearDown(() {
            messenger.setMockMethodCallHandler(channel, null);
            FlutterSecureStoragePlatform.instance = previous;
          });
          final credentials = ArrCredentialsStore(servicePrefix: service);
          final marker = DirectCredentialService.values
              .byName(service)
              .pendingMutationKey;
          await expectLater(
            credentials.save(
              baseUrl: 'https://replacement.example.test',
              apiKey: 'synthetic-new-key',
            ),
            throwsA(isA<DirectHomeAccessException>()),
          );
          expect(
            secure.values['${service}_base_url'],
            'https://replacement.example.test',
          );
          expect(
            secure.values['${service}_api_key'],
            old['${service}_api_key'],
          );
          expect(secure.values[marker], '1');
          final repository = BackupRepository();
          await expectLater(repository.capture(_connections), _pending);
          await expectLater(repository.preview(_snapshot(service)), _pending);
          await expectLater(
            repository.restore(
              _snapshot(service),
              _connections,
              conflictPolicy: BackupConflictPolicy.replaceSelected,
            ),
            _pending,
          );
          expect(secure.values[marker], '1');
          failUrlWrite = false;
          if (recovery == 'save') {
            await credentials.save(
              baseUrl: 'https://replacement.example.test',
              apiKey: 'synthetic-new-key',
            );
          } else {
            await credentials.clear();
          }
          expect(secure.values, isNot(contains(marker)));
          final captured = (await repository.capture(_connections)).toJson();
          expect(
            (captured['groups'] as Map)['connections'],
            recovery == 'save'
                ? {
                    service: {
                      'baseUrl': 'https://replacement.example.test',
                      'apiKey': 'synthetic-new-key',
                    },
                  }
                : isEmpty,
          );
          expect(jsonEncode(captured), isNot(contains(marker)));
          expect((await repository.preview(_snapshot(service))).services, [
            service,
          ]);
          await repository.restore(
            _snapshot(service),
            _connections,
            conflictPolicy: BackupConflictPolicy.replaceSelected,
          );
          expect(
            (await credentials.read())!.baseUrl,
            _record(service)['baseUrl'],
          );
          expect(secure.values, isNot(contains(marker)));
        },
      );
    }
  }

  test(
    'non-string platform marker fails closed instead of implying absence',
    () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final previous = FlutterSecureStoragePlatform.instance;
      FlutterSecureStoragePlatform.instance =
          MethodChannelFlutterSecureStorage();
      final marker = DirectCredentialService.sonarr.pendingMutationKey;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'read') fail('Unexpected mutation');
        return (call.arguments as Map)['key'] == marker ? false : null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        FlutterSecureStoragePlatform.instance = previous;
      });
      final repository = BackupRepository(
        storage: PlatformBackupStorage(
          secureStorage: const FlutterSecureStorage(),
        ),
      );
      await expectLater(repository.capture(_connections), _pending);
      await expectLater(repository.preview(_snapshot('sonarr')), _pending);
      await expectLater(
        repository.restore(_snapshot('sonarr'), _connections),
        _pending,
      );
    },
  );
}
