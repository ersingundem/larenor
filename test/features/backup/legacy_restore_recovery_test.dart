import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';

import 'backup_test_storage.dart';

const _key = BackupRepository.restoreJournalKey;
final _journal = jsonEncode({
  'version': 1,
  'changes': [
    {'secret': false, 'key': 'appearance', 'before': 'dark'},
  ],
});

class _Storage extends MemoryBackupStorage {
  _Storage(String current)
    : super(preferences: {'appearance': current}, secrets: {_key: _journal});
  void Function()? afterRead;
  @override
  Future<Object?> readPreference(String key) async {
    final value = await super.readPreference(key);
    afterRead?.call();
    return value;
  }
}

void main() {
  for (final current in ['light', 'system']) {
    test(
      'legacy before-only journal cannot infer an after value $current',
      () async {
        final storage = _Storage(current);
        await expectLater(
          BackupRepository(storage: storage).recoverPendingRestore(),
          throwsA(isA<BackupException>()),
        );
        expect(storage.preferences['appearance'], current);
        expect(storage.secrets[_key], _journal);
        expect(storage.writes, isEmpty);
      },
    );
  }
  test(
    'already restored legacy before values need only private journal cleanup',
    () async {
      final storage = _Storage('dark');
      expect(
        await BackupRepository(storage: storage).recoverPendingRestore(),
        isTrue,
      );
      expect(storage.writes, ['secret:$_key']);
      expect(storage.preferences['appearance'], 'dark');
      expect(storage.secrets, isEmpty);
    },
  );
  test(
    'legacy cleanup cannot delete a replacement or alter any target',
    () async {
      final storage = _Storage('dark')..afterRead = () {};
      storage.afterRead = () =>
          storage.secrets[_key] = 'replacement-legacy-intent';
      await expectLater(
        BackupRepository(storage: storage).recoverPendingRestore(),
        throwsA(isA<BackupException>()),
      );
      expect(storage.secrets[_key], 'replacement-legacy-intent');
      expect(storage.writes, isEmpty);
    },
  );
}
