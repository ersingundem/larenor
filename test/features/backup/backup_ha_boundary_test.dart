import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Uses the pinned secure-storage plugin's public platform test seam.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/backup/data/backup_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/direct_home_boundary_test.dart' as auth_fixture;
import 'backup_test_storage.dart';

const _connections = BackupSelection(
  settings: false,
  dashboard: false,
  connections: true,
);
const _local = BackupSelection();
const _marker = CredentialsStore.pendingMutationKey;
const _oldPair = {
  'ha_base_url': 'https://old.example.test',
  'ha_token': 'synthetic-old-token',
};
const _incoming = {
  'ha': {'baseUrl': 'https://new.example.test', 'token': 'synthetic-new-token'},
};
const _layout = {
  'rooms': [],
  'tiles': [],
  'favoriteEntityIds': [],
  'hiddenEntityIds': [],
};

BackupSnapshot _snapshot({bool connections = true}) => BackupSnapshot.fromJson({
  'version': 1,
  'createdAt': '2026-09-06T00:00:00.000Z',
  'groups': {
    'settings': {'appearance': 'dark'},
    'dashboard': _layout,
    if (connections) 'connections': _incoming,
  },
});

Matcher get _pending => throwsA(
  isA<BackupException>()
      .having((e) => e.code, 'code', 'ha_connection_pending')
      .having(
        (e) => e.toString(),
        'static safe message',
        'Reconnect Home Assistant before backing up or restoring connections.',
      ),
);

class _Storage extends MemoryBackupStorage {
  _Storage({super.preferences, super.secrets});
  Future<void> Function(String)? afterRead;
  Future<void> Function(String)? afterWrite;
  Object? markerFailure;

  @override
  Future<String?> readSecret(String key) async {
    if (key == _marker && markerFailure != null) throw markerFailure!;
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

  for (final value in ['1', '', 'false', 'unknown-private-marker']) {
    test(
      'capture refuses pending marker ${value.length} without reading pair',
      () async {
        final storage = _Storage(secrets: {..._oldPair, _marker: value});
        await expectLater(
          BackupRepository(storage: storage).capture(_connections),
          _pending,
        );
        expect(storage.reads, isNot(contains('secret:ha_token')));
        expect(storage.reads, isNot(contains('secret:ha_base_url')));
        expect(storage.writes, isEmpty);
        expect(storage.secrets[_marker], value);
      },
    );
  }

  for (final operation in ['preview', 'keep', 'replace']) {
    test(
      '$operation refuses pending even when imported HA pair is complete',
      () async {
        final storage = _Storage(secrets: {..._oldPair, _marker: '1'});
        final repository = BackupRepository(storage: storage);
        await expectLater(
          operation == 'preview'
              ? repository.preview(_snapshot())
              : repository.restore(
                  _snapshot(),
                  _connections,
                  conflictPolicy: operation == 'replace'
                      ? BackupConflictPolicy.replaceSelected
                      : BackupConflictPolicy.keepExisting,
                ),
          _pending,
        );
        expect(storage.writes, isEmpty);
        expect(storage.secrets, {..._oldPair, _marker: '1'});
      },
    );
  }

  test(
    'HA pending does not block an imported unrelated Sonarr record',
    () async {
      final storage = _Storage(secrets: {_marker: '1'});
      final backup = BackupSnapshot.fromJson({
        'version': 1,
        'createdAt': '2026-09-06T00:00:00.000Z',
        'groups': {
          'connections': {
            'sonarr': {
              'baseUrl': 'https://arr.example.test',
              'apiKey': 'synthetic',
            },
          },
        },
      });
      final repository = BackupRepository(storage: storage);
      expect((await repository.preview(backup)).services, ['sonarr']);
      await repository.restore(backup, _connections);
      expect(storage.secrets['sonarr_api_key'], 'synthetic');
      expect(storage.secrets[_marker], '1');
      expect(storage.reads, isNot(contains('secret:$_marker')));
      expect(storage.writes, isNot(contains('secret:$_marker')));
    },
  );

  for (final failure in [
    StateError('synthetic private detail'),
    const FormatException('synthetic private detail'),
    PlatformException(code: 'private', message: 'synthetic private detail'),
  ]) {
    test(
      'marker ${failure.runtimeType} fails closed and remains static',
      () async {
        final storage = _Storage(secrets: _oldPair)..markerFailure = failure;
        final repository = BackupRepository(storage: storage);
        await expectLater(repository.capture(_connections), _pending);
        await expectLater(repository.preview(_snapshot()), _pending);
        await expectLater(
          repository.restore(_snapshot(), _connections),
          _pending,
        );
        expect(storage.writes, isEmpty);
      },
    );
  }

  test(
    'platform non-string marker is unknown, never evidence of absence',
    () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final previous = FlutterSecureStoragePlatform.instance;
      FlutterSecureStoragePlatform.instance =
          MethodChannelFlutterSecureStorage();
      final readKeys = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'read') fail('Unexpected secure storage mutation');
        final key = (call.arguments as Map)['key'] as String;
        readKeys.add(key);
        if (key == _marker) return false;
        return null;
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
      await expectLater(repository.preview(_snapshot()), _pending);
      await expectLater(
        repository.restore(_snapshot(), _connections),
        _pending,
      );
      expect(readKeys, contains(_marker));
      expect(readKeys, isNot(contains('ha_token')));
    },
  );

  test(
    'settings and dashboard only do not inspect or reset pending connection',
    () async {
      final storage = _Storage(
        secrets: {..._oldPair, _marker: '1'},
        preferences: {'appearance': 'light'},
      )..markerFailure = StateError('Marker must not be read');
      final repository = BackupRepository(storage: storage);
      final captured = await repository.capture(_local);
      expect(captured.hasConnections, isFalse);
      expect(
        (await repository.preview(_snapshot(connections: false)))
            .hasConnections,
        isFalse,
      );
      await repository.restore(
        _snapshot(),
        _local,
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      );
      expect(storage.preferences['appearance'], 'dark');
      expect(storage.preferences['dashboard_layout'], jsonEncode(_layout));
      expect(storage.secrets[_marker], '1');
      expect(storage.secrets['ha_token'], _oldPair['ha_token']);
      expect(storage.reads, isNot(contains('secret:$_marker')));
      expect(storage.writes, isNot(contains('secret:$_marker')));
      expect(jsonEncode(captured.toJson()), isNot(contains(_marker)));
    },
  );

  test('capture rejects marker appearing during pair read before publishing snapshot', () async {
    final storage = _Storage(secrets: _oldPair);
    storage.afterRead = (key) async {
      if (key == 'ha_token') storage.secrets[_marker] = '1';
    };
    await expectLater(
      BackupRepository(storage: storage).capture(_connections),
      _pending,
    );
    expect(storage.writes, isEmpty);
  });

  test(
    'preview rejects marker appearing during final dashboard read',
    () async {
      final storage = _Storage(secrets: _oldPair);
      storage.afterRead = (key) async {
        if (key == 'dashboard_layout') storage.secrets[_marker] = '1';
      };
      await expectLater(
        BackupRepository(storage: storage).preview(_snapshot()),
        _pending,
      );
      expect(storage.writes, isEmpty);
    },
  );

  test(
    'restore cannot journal pair when marker appears during capture',
    () async {
      final storage = _Storage(secrets: _oldPair);
      storage.afterRead = (key) async {
        if (key == 'ha_token') storage.secrets[_marker] = '1';
      };
      await expectLater(
        BackupRepository(storage: storage).restore(
          _snapshot(),
          _connections,
          conflictPolicy: BackupConflictPolicy.replaceSelected,
        ),
        _pending,
      );
      expect(storage.writes, isEmpty);
      expect(storage.secrets['ha_token'], _oldPair['ha_token']);
    },
  );

  test(
    'capture joins pending credential mutation before checking marker',
    () async {
      final storage = _Storage(secrets: _oldPair);
      final started = Completer<void>();
      final release = Completer<void>();
      final mutation = ConfigurationWrites.run(() async {
        started.complete();
        await release.future;
        await storage.writeSecret(_marker, '1');
        await storage.writeSecret(
          'ha_base_url',
          'https://partial.example.test',
        );
      });
      await started.future;
      final captured = BackupRepository(storage: storage).capture(_connections);
      final rejection = expectLater(captured, _pending);
      expect(storage.reads, isEmpty);
      release.complete();
      await mutation;
      await rejection;
      expect(storage.reads, isNot(contains('secret:ha_token')));
    },
  );

  test('marker arriving with durable journal triggers bounded rollback, not commit', () async {
    final storage = _Storage(secrets: _oldPair);
    storage.afterWrite = (key) async {
      if (key == BackupRepository.restoreJournalKey) {
        storage.secrets[_marker] = '1';
      }
    };
    await expectLater(
      BackupRepository(storage: storage).restore(
        _snapshot(),
        _connections,
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      ),
      _pending,
    );
    expect(storage.secrets, {..._oldPair, _marker: '1'});
    expect(storage.writes, isNot(contains('secret:$_marker')));
    expect(
      storage.writes.first,
      'secret:${BackupRepository.restoreJournalKey}',
    );
    expect(storage.writes.last, 'secret:${BackupRepository.restoreJournalKey}');
  });

  test('marker arriving during restore does not commit; failed rollback remains recoverable', () async {
    final storage = _Storage(secrets: _oldPair)..failWrites.add(5);
    storage.afterWrite = (key) async {
      if (key == 'ha_token') storage.secrets[_marker] = '1';
    };
    await expectLater(
      BackupRepository(storage: storage).restore(
        _snapshot(),
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
    expect(storage.secrets[_marker], '1');
    expect(storage.secrets, contains(BackupRepository.restoreJournalKey));
    storage.failWrites.clear();
    expect(
      await BackupRepository(storage: storage).recoverPendingRestore(),
      isTrue,
    );
    expect(storage.secrets, {..._oldPair, _marker: '1'});
    expect(storage.writes, isNot(contains('secret:$_marker')));
  });

  test(
    'existing restore journal recovers without reading or resetting HA marker',
    () async {
      final storage = _Storage(secrets: _oldPair);
      await BackupRepository(storage: storage).restore(
        _snapshot(),
        _connections,
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      );
      final interrupted = storage.durableImages.where(
        (image) =>
            image.secrets.containsKey(BackupRepository.restoreJournalKey),
      );
      expect(interrupted, isNotEmpty);
      for (final image in interrupted) {
        final pending = _Storage(secrets: {...image.secrets, _marker: '1'})
          ..markerFailure = StateError('Recovery must not read marker');
        expect(
          await BackupRepository(storage: pending).recoverPendingRestore(),
          isTrue,
        );
        expect(pending.secrets, {..._oldPair, _marker: '1'});
        expect(pending.writes, isNot(contains('secret:$_marker')));
        expect(
          await BackupRepository(storage: pending).recoverPendingRestore(),
          isFalse,
        );
        await expectLater(
          BackupRepository(storage: pending).capture(_connections),
          _pending,
        );
      }
    },
  );

  test('failed recovery retains both journals and later retry never clears HA marker', () async {
    final journal = jsonEncode({
      'version': 1,
      'changes': [
        {'secret': true, 'key': 'ha_token', 'before': _oldPair['ha_token']},
      ],
    });
    final storage = _Storage(
      secrets: {
        _marker: '1',
        BackupRepository.restoreJournalKey: journal,
        'ha_token': 'partial',
      },
    )..failWrites.add(1);
    final repository = BackupRepository(storage: storage);
    await expectLater(
      repository.recoverPendingRestore(),
      throwsA(isA<BackupRestoreException>()),
    );
    expect(storage.secrets[BackupRepository.restoreJournalKey], journal);
    expect(storage.secrets[_marker], '1');
    storage.failWrites.clear();
    expect(await repository.recoverPendingRestore(), isTrue);
    expect(storage.secrets[_marker], '1');
    expect(storage.secrets['ha_token'], _oldPair['ha_token']);
  });

  test(
    'marker is neither backup data nor an allowed rollback target',
    () async {
      expect(backupPreferenceKeys, isNot(contains(_marker)));
      expect(
        backupConnectionFields.values.expand((fields) => fields.values),
        isNot(contains(_marker)),
      );
      final storage = _Storage(
        secrets: {
          _marker: '1',
          BackupRepository.restoreJournalKey: jsonEncode({
            'version': 1,
            'changes': [
              {'secret': true, 'key': _marker, 'before': null},
            ],
          }),
        },
      );
      await expectLater(
        BackupRepository(storage: storage).recoverPendingRestore(),
        throwsA(isA<BackupException>()),
      );
      expect(storage.writes, isEmpty);
      expect(storage.secrets[_marker], '1');
      expect(
        () => BackupSnapshot.fromJson({
          'version': 1,
          'createdAt': '2026-09-06T00:00:00.000Z',
          'groups': {
            'connections': {
              'ha': {..._incoming['ha']!, _marker: '1'},
            },
          },
        }),
        throwsA(isA<BackupValidationException>()),
      );
    },
  );

  test(
    'actual platform capture refuses marked pair and preserves marker',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({..._oldPair, _marker: '1'});
      await expectLater(BackupRepository().capture(_connections), _pending);
      expect(await const FlutterSecureStorage().read(key: _marker), '1');
    },
  );

  for (final recovery in ['save', 'clear']) {
    test(
      'real CredentialsStore partial save cannot escape backup until explicit $recovery',
      () async {
        SharedPreferences.setMockInitialValues({});
        final secure = auth_fixture.SecurePlatform();
        secure.values
          ..clear()
          ..addAll(_oldPair);
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
              (call.arguments as Map)['key'] == 'ha_base_url') {
            throw PlatformException(
              code: 'synthetic',
              message: 'synthetic private payload',
            );
          }
          return result;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          FlutterSecureStoragePlatform.instance = previous;
        });
        final credentials = CredentialsStore();
        const replacement = HaConnectionConfig(
          baseUrl: 'https://replacement.example.test',
          token: 'synthetic-replacement-token',
        );
        await expectLater(
          credentials.save(replacement),
          throwsA(isA<Exception>()),
        );
        expect(secure.values['ha_base_url'], replacement.baseUrl);
        expect(secure.values['ha_token'], _oldPair['ha_token']);
        expect(secure.values[_marker], '1');
        final backup = BackupRepository();
        final callCount = secure.calls.length;
        await expectLater(backup.capture(_connections), _pending);
        await expectLater(backup.preview(_snapshot()), _pending);
        await expectLater(backup.restore(_snapshot(), _connections), _pending);
        expect(
          secure.calls
              .skip(callCount)
              .every(
                (call) =>
                    call.$1 == 'read' &&
                    (call.$2 == _marker ||
                        call.$2 == BackupRepository.restoreJournalKey),
              ),
          isTrue,
        );
        failUrlWrite = false;
        if (recovery == 'save') {
          await credentials.save(replacement);
        } else {
          await credentials.clear();
        }
        expect(secure.values, isNot(contains(_marker)));
        final captured = (await backup.capture(_connections)).toJson();
        final records = (captured['groups'] as Map)['connections'] as Map;
        expect(
          records,
          recovery == 'save'
              ? {
                  'ha': {
                    'baseUrl': replacement.baseUrl,
                    'token': replacement.token,
                  },
                }
              : isEmpty,
        );
        expect(jsonEncode(captured), isNot(contains(_marker)));
      },
    );
  }
}
