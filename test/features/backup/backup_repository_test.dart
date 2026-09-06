import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_store.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_disclosure_policy.dart';

import 'backup_test_storage.dart';

BackupSnapshot snapshot(Map<String, dynamic> groups) => BackupSnapshot.fromJson(
  {'version': 1, 'createdAt': '2026-09-05T00:00:00.000Z', 'groups': groups},
);

void main() {
  const all = BackupSelection(
    settings: true,
    dashboard: true,
    connections: true,
  );
  const connections = BackupSelection(
    settings: false,
    dashboard: false,
    connections: true,
  );
  const credentialRecord = {
    'baseUrl': 'http://192.0.2.1:8123/proxy',
    'token': 'fixture-ha-token',
  };

  test('default capture reads allowlisted preferences without exporting secrets or PIN', () async {
    final storage = MemoryBackupStorage(
      preferences: {'appearance': 'dark', 'unrelated': 'private'},
      secrets: {
        'ha_base_url': 'http://192.0.2.1:8123',
        'ha_token': 'fixture-ha-token',
        'settings_pin': '123456',
        'settings_pin_attempts': '{"failures":5}',
        'cookie': 'fixture-cookie',
      },
    );
    final backup = await BackupRepository(storage: storage)
        .capture(const BackupSelection());
    final json = jsonEncode(backup.toJson());
    expect(json, contains('dark'));
    expect(json, isNot(contains('fixture-ha-token')));
    expect(json, isNot(contains('private')));
    expect(json, isNot(contains('settings_pin')));
    expect(storage.reads.where((key) => key.startsWith('secret:')), [
      'secret:${BackupRepository.restoreJournalKey}',
      'secret:backup_restore_journal_v2',
      'secret:${WellbeingDisclosureStore.storageKey}',
      'secret:${WellbeingStore.storageKey}',
    ]);
  });

  test(
    'captures default null settings and an actual DashboardLayout roundtrip',
    () async {
      const layout = DashboardLayout(
        rooms: [
          DashboardRoom(
            id: 'room1',
            name: 'Kitchen',
            entityIds: ['light.kitchen'],
          ),
        ],
        tiles: [
          TileConfig(
            id: 'web',
            type: TileType.webview,
            x: 0,
            y: 0,
            width: 3,
            height: 2,
            url: 'https://example.test/weather',
          ),
        ],
        favoriteEntityIds: ['light.kitchen'],
      );
      final fromModel = snapshot({'dashboard': layout.toJson()});
      final storage = MemoryBackupStorage(
        preferences: {'dashboard_layout': jsonEncode(layout.toJson())},
      );
      final repo = BackupRepository(storage: storage);
      final captured = await repo.capture(const BackupSelection());
      expect((captured.toJson()['groups'] as Map)['settings'], {
        for (final key in backupPreferenceKeys) key: null,
      });
      expect(
        (captured.toJson()['groups'] as Map)['dashboard'],
        (fromModel.toJson()['groups'] as Map)['dashboard'],
      );
      final target = MemoryBackupStorage();
      await BackupRepository(storage: target)
          .restore(captured, const BackupSelection());
      expect(
        DashboardLayout.fromJson(
          jsonDecode(target.preferences['dashboard_layout'] as String),
        ),
        layout,
      );
      expect(target.preferences['enabled_services_migrated'], isTrue);
    },
  );

  test('connections are explicit complete URL-bound records; runtime identity and PIN excluded', () async {
    final storage = MemoryBackupStorage(
      secrets: {
        'ha_base_url': credentialRecord['baseUrl']!,
        'ha_token': credentialRecord['token']!,
        'jellyfin_base_url': 'http://192.0.2.2:8096',
        'jellyfin_user_id': 'fixture-user',
        'jellyfin_access_token': 'fixture-jellyfin-token',
        'jellyfin_device_id': 'old-device',
        'settings_pin': '123456',
        'PVEAuthCookie': 'fixture-ticket',
      },
    );
    final backup = await BackupRepository(storage: storage)
        .capture(connections);
    final json = jsonEncode(backup.toJson());
    expect(json, contains('fixture-ha-token'));
    expect(json, isNot(contains('old-device')));
    expect(json, isNot(contains('fixture-ticket')));
    expect(json, isNot(contains('123456')));
    final target = MemoryBackupStorage(
      secrets: {'settings_pin': '654321', 'jellyfin_device_id': 'local-device'},
    );
    await BackupRepository(storage: target).restore(backup, connections);
    expect(target.secrets['settings_pin'], '654321');
    expect(target.secrets['jellyfin_device_id'], 'local-device');
    expect(target.secrets['ha_token'], 'fixture-ha-token');
  });

  test('new-install restore never copies Jellyfin deviceId or enables Proxmox TLS exception', () async {
    final backup = snapshot({
      'connections': {
        'proxmox': {
          'host': '2001:db8::1',
          'port': '8006',
          'username': 'fixture-user',
          'realm': 'pam',
          'password': 'fixture-password',
          'allowSelfSigned': 'true',
        },
      },
    });
    final target = MemoryBackupStorage();
    final repo = BackupRepository(storage: target);
    expect((await repo.preview(backup)).requiresCertificateReview, isTrue);
    await repo.restore(backup, connections);
    expect(target.secrets['proxmox_host'], '2001:db8::1');
    expect(target.secrets['proxmox_port'], '8006');
    expect(target.secrets['proxmox_allow_self_signed'], 'false');
    expect(target.secrets, isNot(contains('jellyfin_device_id')));
  });

  test(
    'keepExisting treats credentials as one record, never mixing URL and token',
    () async {
      final target = MemoryBackupStorage(
        preferences: {'appearance': 'light'},
        secrets: {'ha_base_url': 'https://old.example.test'},
      );
      final backup = snapshot({
        'settings': {'appearance': 'dark', 'keep_screen_on': true},
        'connections': {'ha': credentialRecord},
      });
      final repo = BackupRepository(storage: target);
      final preview = await repo.preview(backup);
      expect(preview.existingServices, ['ha']);
      expect(preview.existingSettingsCount, 1);
      expect(preview.services, ['ha']);
      expect(preview.toString(), isNot(contains('fixture-ha-token')));
      await repo.restore(backup, all);
      expect(target.preferences['appearance'], 'light');
      expect(target.preferences['keep_screen_on'], isTrue);
      expect(target.secrets['ha_base_url'], 'https://old.example.test');
      expect(target.secrets, isNot(contains('ha_token')));
      await repo.restore(
        backup,
        all,
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      );
      expect(target.preferences['appearance'], 'dark');
      expect(target.secrets['ha_base_url'], credentialRecord['baseUrl']);
      expect(target.secrets['ha_token'], credentialRecord['token']);
    },
  );

  test(
    'deselected groups remain untouched and snapshot is immutable',
    () async {
      final source = {
        'settings': {'appearance': 'dark'},
        'connections': {'ha': credentialRecord},
      };
      final backup = snapshot(source);
      source['settings'] = {'settings_pin': 'invalid'};
      final copy = backup.toJson();
      (copy['groups'] as Map)['connections'] = {'unknown': {}};
      final target = MemoryBackupStorage(
        secrets: {'ha_token': 'existing-token'},
      );
      await BackupRepository(storage: target)
          .restore(backup, const BackupSelection(dashboard: false));
      expect(target.preferences['appearance'], 'dark');
      expect(target.secrets['ha_token'], 'existing-token');
    },
  );

  test(
    'storage failure restores all prior values and clears recovery journal',
    () async {
      final target = MemoryBackupStorage(
        preferences: {'appearance': 'light'},
        secrets: {
          'ha_base_url': 'https://old.example.test',
          'ha_token': 'old-token',
        },
      )..failWrites.add(4);
      final backup = snapshot({
        'settings': {'appearance': 'dark'},
        'connections': {'ha': credentialRecord},
      });
      await expectLater(
        BackupRepository(storage: target).restore(
          backup,
          all,
          conflictPolicy: BackupConflictPolicy.replaceSelected,
        ),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.rollbackComplete,
            'rollback',
            isTrue,
          ),
        ),
      );
      expect(target.preferences, {'appearance': 'light'});
      expect(target.secrets, {
        'ha_base_url': 'https://old.example.test',
        'ha_token': 'old-token',
      });
      expect(
        target.writes.first,
        'secret:${BackupRepository.restoreJournalKey}',
      );
    },
  );

  test(
    'failed rollback retains journal and startup recovery finishes later',
    () async {
      final target = MemoryBackupStorage(
        preferences: {'appearance': 'light'},
        secrets: {
          'ha_base_url': 'https://old.example.test',
          'ha_token': 'old-token',
        },
      )..failWrites.addAll({4, 5});
      final repo = BackupRepository(storage: target);
      final backup = snapshot({
        'settings': {'appearance': 'dark'},
        'connections': {'ha': credentialRecord},
      });
      await expectLater(
        repo.restore(
          backup,
          all,
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
      expect(target.secrets, contains(BackupRepository.restoreJournalKey));
      await expectLater(
        repo.capture(all),
        throwsA(
          isA<BackupException>().having(
            (e) => e.code,
            'code',
            'recovery_required',
          ),
        ),
      );
      target.failWrites.clear();
      expect(await repo.recoverPendingRestore(), isTrue);
      expect(target.preferences, {'appearance': 'light'});
      expect(target.secrets, {
        'ha_base_url': 'https://old.example.test',
        'ha_token': 'old-token',
      });
      expect(await repo.recoverPendingRestore(), isFalse);
    },
  );

  test('every interrupted durable write state recovers before providers may read it', () async {
    final initialPrefs = <String, Object?>{'appearance': 'light'};
    final initialSecrets = {
      'ha_base_url': 'https://old.example.test',
      'ha_token': 'old-token',
    };
    final target = MemoryBackupStorage(
      preferences: initialPrefs,
      secrets: initialSecrets,
    );
    final backup = snapshot({
      'settings': {'appearance': 'dark'},
      'connections': {'ha': credentialRecord},
    });
    await BackupRepository(storage: target).restore(
      backup,
      all,
      conflictPolicy: BackupConflictPolicy.replaceSelected,
    );
    final interrupted = target.durableImages.where(
      (image) => image.secrets.containsKey(BackupRepository.restoreJournalKey),
    );
    // Journal + display privacy policy + appearance + complete HA record.
    expect(interrupted.length, 5);
    for (final (index, image) in interrupted.indexed) {
      if (index == 0) {
        expect(
          await BackupRepository(storage: image).recoverPendingRestore(),
          isTrue,
        );
        expect(image.preferences, initialPrefs);
        expect(image.secrets, initialSecrets);
      } else {
        final prefs = Map.of(image.preferences),
            secrets = Map.of(image.secrets);
        await expectLater(
          BackupRepository(storage: image).recoverPendingRestore(),
          throwsA(isA<BackupException>()),
        );
        expect(image.preferences, prefs);
        expect(image.secrets, secrets);
        expect(image.writes, isEmpty);
      }
    }
    final committed = target.durableImages.last;
    expect(
      await BackupRepository(storage: committed).recoverPendingRestore(),
      isFalse,
    );
    expect(committed.secrets['ha_token'], 'fixture-ha-token');
  });

  test('recovery journal cannot target PIN or unknown storage keys', () async {
    final target = MemoryBackupStorage(
      secrets: {
        BackupRepository.restoreJournalKey: jsonEncode({
          'version': 1,
          'changes': [
            {'secret': true, 'key': 'settings_pin', 'before': null},
          ],
        }),
        'settings_pin': '123456',
      },
    );
    await expectLater(
      BackupRepository(storage: target).recoverPendingRestore(),
      throwsA(isA<BackupException>()),
    );
    expect(target.writes, isEmpty);
    expect(target.secrets['settings_pin'], '123456');
    expect(target.secrets, contains(BackupRepository.restoreJournalKey));
  });

  test(
    'capture joins global multi-key write queue before reading credentials',
    () async {
      final target = MemoryBackupStorage();
      final write = ConfigurationWrites.run(() async {
        await target.writeSecret('ha_base_url', credentialRecord['baseUrl']);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await target.writeSecret('ha_token', credentialRecord['token']);
      });
      final captured = BackupRepository(storage: target).capture(connections);
      await write;
      expect(((await captured).toJson()['groups'] as Map)['connections'], {
        'ha': credentialRecord,
      });
    },
  );
}
