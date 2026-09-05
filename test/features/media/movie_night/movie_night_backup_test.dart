import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/media/movie_night/domain/movie_night_preset.dart';

import '../../backup/backup_test_storage.dart';

void main() {
  test(
    'portable backup retains scene choices without executing either scene',
    () async {
      const preset = MovieNightPreset(
        serverUrl: 'https://ha.test',
        startEntityId: 'scene.cinema',
        finishEntityId: 'scene.finish',
      );
      final snapshot = BackupSnapshot.fromJson({
        'version': 1,
        'createdAt': '2026-09-05T00:00:00.000Z',
        'groups': {
          'settings': {MovieNightPreset.storageKey: preset.encodeStored()},
        },
      });
      final storage = MemoryBackupStorage();
      await BackupRepository(storage: storage)
          .restore(snapshot, const BackupSelection());
      final restored = MovieNightPreset.decodeStored(
        storage.preferences[MovieNightPreset.storageKey]!,
      );
      expect(restored.startEntityId, 'scene.cinema');
      expect(restored.finishEntityId, 'scene.finish');
      expect(storage.secrets, isEmpty);
    },
  );

  test(
    'backup validator rejects unsupported scene-control payload before restore',
    () {
      expect(
        () => BackupSnapshot.fromJson({
          'version': 1,
          'createdAt': '2026-09-05T00:00:00.000Z',
          'groups': {
            'settings': {
              MovieNightPreset.storageKey: jsonEncode({
                'version': 1,
                'serverUrl': 'https://ha.test',
                'startEntityId': 'lock.front_door',
              }),
            },
          },
        }),
        throwsA(isA<BackupValidationException>()),
      );
    },
  );
}
