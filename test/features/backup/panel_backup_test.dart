import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ambient/domain/ambient_settings.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';
import 'package:larenor/features/web_panel/domain/web_panel_options.dart';

import 'backup_test_storage.dart';

const _settingsOnly = BackupSelection(
  settings: true,
  dashboard: false,
  connections: false,
);

BackupSnapshot _legacy(Map<String, dynamic> settings) =>
    BackupSnapshot.fromJson({
      'version': 1,
      'createdAt': '2026-09-05T00:00:00Z',
      'groups': {'settings': settings},
    });

void main() {
  final program = ScreenProgram(
    enabled: true,
    rules: [
      ScreenProgramRule(
        id: 'weekend',
        days: {6, 7},
        startMinutes: 1320,
        endMinutes: 480,
        dim: true,
        awake: ScreenAwakeMode.systemTimeout,
      ),
    ],
  ).encode();
  final ambient = const AmbientSettings(
    photosEnabled: true,
    intervalSeconds: 60,
    fit: AmbientPhotoFit.cover,
  ).encode();

  test(
    'panel settings and explicit website options survive vault roundtrip',
    () async {
      final layout = DashboardLayout(
        tiles: [
          TileConfig(
            id: 'weather',
            type: TileType.webview,
            x: 0,
            y: 0,
            width: 2,
            height: 2,
            url: 'https://example.test/weather',
            webPanel: WebPanelOptions(
              additionalOrigins: ['https://login.example.test'],
              textZoom: 150,
              zoomEnabled: false,
            ),
          ),
        ],
      );
      final source = MemoryBackupStorage(
        preferences: {
          ScreenProgram.preferenceKey: program,
          AmbientSettings.preferenceKey: ambient,
          'dashboard_layout': jsonEncode(layout.toJson()),
          'ambient_photos': '/private/album.png',
          'website_cookies': 'private cookie',
        },
      );
      final snapshot = await BackupRepository(storage: source)
          .capture(const BackupSelection());
      final encoded = jsonEncode(snapshot.toJson());
      expect(encoded, isNot(contains('/private/album.png')));
      expect(encoded, isNot(contains('private cookie')));
      final target = MemoryBackupStorage();
      await BackupRepository(storage: target)
          .restore(snapshot, const BackupSelection());
      expect(target.preferences[ScreenProgram.preferenceKey], program);
      expect(target.preferences[AmbientSettings.preferenceKey], ambient);
      final restored = DashboardLayout.fromJson(
        jsonDecode(target.preferences['dashboard_layout'] as String),
      );
      expect(restored.tiles.single.webPanel, layout.tiles.single.webPanel);
    },
  );

  test(
    'legacy replace clears weekly override but keep existing preserves it',
    () async {
      for (final policy in BackupConflictPolicy.values) {
        final target = MemoryBackupStorage(
          preferences: {ScreenProgram.preferenceKey: program},
        );
        await BackupRepository(storage: target).restore(
          _legacy({'night_start_minutes': 1260, 'night_end_minutes': 480}),
          _settingsOnly,
          conflictPolicy: policy,
        );
        expect(
          target.preferences[ScreenProgram.preferenceKey],
          policy == BackupConflictPolicy.replaceSelected ? null : program,
        );
        expect(target.preferences['night_start_minutes'], 1260);
      }
    },
  );

  test(
    'appearance-only legacy restore does not retire weekly schedule',
    () async {
      final target = MemoryBackupStorage(
        preferences: {ScreenProgram.preferenceKey: program},
      );
      await BackupRepository(storage: target).restore(
        _legacy({'appearance': 'dark'}),
        _settingsOnly,
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      );
      expect(target.preferences[ScreenProgram.preferenceKey], program);
    },
  );

  test(
    'explicit new schedule wins over legacy settings in the same backup',
    () async {
      final target = MemoryBackupStorage();
      await BackupRepository(storage: target).restore(
        _legacy({
          ScreenProgram.preferenceKey: program,
          'night_start_minutes': 1260,
        }),
        _settingsOnly,
        conflictPolicy: BackupConflictPolicy.replaceSelected,
      );
      expect(target.preferences[ScreenProgram.preferenceKey], program);
    },
  );

  test(
    'failed legacy restore rolls back weekly removal with old night settings',
    () async {
      final before = <String, Object?>{
        ScreenProgram.preferenceKey: program,
        'night_start_minutes': 1200,
        'night_end_minutes': 420,
      };
      final target = MemoryBackupStorage(preferences: before)
        ..failWrites.add(4);
      await expectLater(
        BackupRepository(storage: target).restore(
          _legacy({'night_start_minutes': 1260, 'night_end_minutes': 480}),
          _settingsOnly,
          conflictPolicy: BackupConflictPolicy.replaceSelected,
        ),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(target.preferences, before);
      expect(
        target.secrets,
        isNot(contains(BackupRepository.restoreJournalKey)),
      );
      // Legacy boot has only before values: changed crash images stay unresolved.
      for (final crashImage in target.durableImages.where(
        (v) => v.secrets.containsKey(BackupRepository.restoreJournalKey),
      )) {
        if(crashImage.preferences.length==before.length && before.entries.every((entry)=>crashImage.preferences[entry.key]==entry.value)) {
          await BackupRepository(storage: crashImage).recoverPendingRestore();
          expect(crashImage.preferences,before);
        } else {
          final held=jsonEncode([crashImage.preferences,crashImage.secrets]);
          await expectLater(BackupRepository(storage:crashImage).recoverPendingRestore(),throwsA(isA<BackupRestoreException>()));
          expect(jsonEncode([crashImage.preferences,crashImage.secrets]),held);
          expect(crashImage.writes,isEmpty);
        }
      }
    },
  );

  test(
    'corrupt panel preferences are rejected before storage access',
    () async {
      for (final settings in [
        {
          ScreenProgram.preferenceKey:
              '{"version":1,"enabled":true,"rules":"invalid"}',
        },
        {AmbientSettings.preferenceKey: '{"version":1,"photosEnabled":true}'},
      ]) {
        expect(
          () => _legacy(settings),
          throwsA(isA<BackupValidationException>()),
        );
      }
    },
  );

  test('backup cannot grant wildcard or non-website panel origins', () {
    for (final mutation in [
      {
        'type': 'entity',
        'webPanel': {
          'additionalOrigins': ['https://example.test'],
        },
      },
      {
        'type': 'webview',
        'webPanel': {
          'additionalOrigins': ['https://*.example.test'],
        },
      },
      {
        'type': 'webview',
        'webPanel': {'textZoom': 10000},
      },
    ]) {
      expect(
        () => BackupSnapshot.fromJson({
          'version': 1,
          'createdAt': '2026-09-05T00:00:00Z',
          'groups': {
            'dashboard':
                DashboardLayout(
                    tiles: [
                      const TileConfig(
                        id: 'web',
                        type: TileType.webview,
                        x: 0,
                        y: 0,
                        width: 2,
                        height: 2,
                        url: 'https://example.test',
                      ),
                    ],
                  ).toJson()
                  ..['tiles'] = [
                    {
                      ...const TileConfig(
                        id: 'web',
                        type: TileType.webview,
                        x: 0,
                        y: 0,
                        width: 2,
                        height: 2,
                        url: 'https://example.test',
                      ).toJson(),
                      ...mutation,
                    },
                  ],
          },
        }),
        throwsA(isA<BackupValidationException>()),
      );
    }
  });
}
