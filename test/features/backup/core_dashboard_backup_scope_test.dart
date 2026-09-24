import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_restore_access.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/server/data/server_session_store.dart';

import 'backup_test_storage.dart';
import 'prepared_restore_test.dart' as prepared;

const _selection = BackupSelection(
  settings: false,
  dashboard: true,
  connections: false,
);

final _scopeA = HomeDataScope.fromJson({
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
  'userId': 'one',
});
final _scopeB = HomeDataScope.fromJson({
  'coreId': 'c' * 32,
  'homeId': 'd' * 32,
  'userId': 'two',
});

String _record(HomeDataScope scope, String room, {int revision = 1}) =>
    jsonEncode({
      'version': 1,
      'scope': scope.toJson(),
      'revision': revision,
      'layout': DashboardLayout(
        rooms: [DashboardRoom(id: room, name: room)],
      ).toJson(),
    });

class _Access implements BackupRestoreAccess {
  _Access(this.scope);
  final HomeDataScope scope;
  bool live = true;

  @override
  HomeSource get source => HomeSource.verifiedCore;

  @override
  Map<String, dynamic> get ownership => {
    'source': source.name,
    'scope': scope.toJson(),
  };

  @override
  DateTime get validUntil => DateTime.utc(2030);

  @override
  void checkLive() {
    if (!live) {
      throw const BackupException('restore_expired', 'Restore expired.');
    }
  }

  @override
  Future<void> checkDurable() async => checkLive();
}

final class _DriftingAccess implements BackupRestoreAccess {
  HomeDataScope scope = _scopeA;
  var checks = 0;

  @override
  HomeSource get source => HomeSource.verifiedCore;
  @override
  Map<String, dynamic> get ownership => {
    'source': source.name,
    'scope': scope.toJson(),
  };
  @override
  DateTime get validUntil => DateTime.utc(2030);
  @override
  void checkLive() {}
  @override
  Future<void> checkDurable() async {
    if (++checks == 2) scope = _scopeB;
  }
}

void main() {
  test(
    'Core capture and prepared restore target only the exact scoped layout',
    () async {
      final storage = MemoryBackupStorage(
        preferences: {
          SharedPreferencesHomeSourceStore.key: HomeSource.verifiedCore.name,
          'dashboard_layout': 'direct-layout-must-not-be-read',
          _scopeA.storageKey: _record(_scopeA, 'A room'),
          _scopeB.storageKey: _record(_scopeB, 'B room'),
        },
        secrets: {
          SecureServerSessionStore.key: prepared.coreSession().encodeStorage(),
        },
      );
      final repository = BackupRepository(storage: storage);
      final snapshot = await repository.capture(
        _selection,
        access: _Access(_scopeA),
      );
      final wire = snapshot.toJson();
      expect(wire['version'], 3);
      expect((wire['groups'] as Map)['dashboardOwner'], {
        'source': 'verifiedCore',
        'scope': _scopeA.toJson(),
      });
      expect(jsonEncode(wire), contains('A room'));
      expect(jsonEncode(wire), isNot(contains('B room')));
      expect(jsonEncode(wire), isNot(contains('direct-layout')));

      storage.preferences[_scopeA.storageKey] = _record(
        _scopeA,
        'Changed A',
        revision: 2,
      );
      final preparedRestore = await repository.prepareRestore(
        snapshot,
        _selection,
        conflictPolicy: BackupConflictPolicy.replaceSelected,
        access: _Access(_scopeA),
      );
      await prepared.apply(preparedRestore);
      final restored = jsonDecode(
        storage.preferences[_scopeA.storageKey]! as String,
      ) as Map<String, dynamic>;
      expect(restored['scope'], _scopeA.toJson());
      expect(restored['revision'], 3);
      expect(restored['layout']['rooms'].single['name'], 'A room');
      expect(
        storage.preferences[_scopeB.storageKey],
        _record(_scopeB, 'B room'),
      );
      expect(
        storage.preferences['dashboard_layout'],
        'direct-layout-must-not-be-read',
      );
    },
  );

  test(
    'same-URL replacement Core cannot preview or write a foreign scoped backup',
    () async {
      final storage = MemoryBackupStorage(
        preferences: {
          SharedPreferencesHomeSourceStore.key: HomeSource.verifiedCore.name,
          _scopeA.storageKey: _record(_scopeA, 'A room'),
          _scopeB.storageKey: _record(_scopeB, 'B room'),
        },
        secrets: {
          SecureServerSessionStore.key: prepared.coreSession().encodeStorage(),
        },
      );
      final repository = BackupRepository(storage: storage);
      final snapshot = await repository.capture(
        _selection,
        access: _Access(_scopeA),
      );
      final before = jsonEncode(storage.preferences);
      await expectLater(
        repository.prepareRestore(
          snapshot,
          _selection,
          conflictPolicy: BackupConflictPolicy.replaceSelected,
          access: _Access(_scopeB),
        ),
        throwsA(
          isA<BackupException>().having(
            (error) => error.code,
            'code',
            'restore_target_mismatch',
          ),
        ),
      );
      expect(jsonEncode(storage.preferences), before);
      expect(storage.writes, isEmpty);
      await expectLater(
        repository.restore(
          snapshot,
          _selection,
          conflictPolicy: BackupConflictPolicy.replaceSelected,
        ),
        throwsA(isA<BackupException>()),
      );
      expect(jsonEncode(storage.preferences), before);
    },
  );

  test('capture rejects ownership drift after the scoped read', () async {
    final storage = MemoryBackupStorage(
      preferences: {_scopeA.storageKey: _record(_scopeA, 'A room')},
    );
    await expectLater(
      BackupRepository(storage: storage)
          .capture(_selection, access: _DriftingAccess()),
      throwsA(
        isA<BackupException>().having(
          (error) => error.code,
          'code',
          'restore_expired',
        ),
      ),
    );
    expect(storage.writes, isEmpty);
    expect(storage.reads, isNot(contains('pref:${_scopeB.storageKey}')));
    expect(storage.reads, isNot(contains('pref:dashboard_layout')));
  });

  test(
    'Core dashboard owner is exact and cannot be injected into legacy data',
    () {
      final valid = {
        'version': 3,
        'createdAt': '2026-09-24T00:00:00Z',
        'groups': {
          'privacy': {
            'version': 1,
            'entityIds': <String>[],
            'reviewRequired': true,
          },
          'dashboard': const DashboardLayout().toJson(),
          'dashboardOwner': {
            'source': 'verifiedCore',
            'scope': _scopeA.toJson(),
          },
        },
      };
      expect(() => BackupSnapshot.fromJson(valid), returnsNormally);
      for (final invalid in [
        {...valid, 'version': 2},
        {
          ...valid,
          'groups': {
            ...(valid['groups'] as Map),
            'dashboardOwner': {
              'source': 'verifiedCore',
              'scope': {..._scopeA.toJson(), 'token': 'forbidden'},
            },
          },
        },
        {
          ...valid,
          'groups': {...(valid['groups'] as Map)..remove('dashboard')},
        },
      ]) {
        expect(
          () => BackupSnapshot.fromJson(
            jsonDecode(jsonEncode(invalid)) as Map<String, dynamic>,
          ),
          throwsA(isA<BackupValidationException>()),
        );
      }
    },
  );
}
