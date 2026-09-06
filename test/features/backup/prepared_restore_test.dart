import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_restore_access.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'backup_test_storage.dart';

class TestRestoreAccess implements BackupRestoreAccess {
  bool live = true, durable = true;
  @override
  HomeSource source = HomeSource.directLocal;
  @override
  Map<String, dynamic> get ownership => {'source': source.name, if(source==HomeSource.verifiedCore) 'scope':{'coreId':'a'*32,'homeId':'b'*32,'userId':'one'}};
  @override
  DateTime get validUntil => DateTime.utc(2030);
  @override
  void checkLive() { if (!live) throw const BackupException('restore_expired', 'Restore expired.'); }
  @override
  Future<void> checkDurable() async { if (!durable) throw const BackupException('restore_expired', 'Restore expired.'); }
}

ServerSession coreSession()=>ServerSession(endpoint:ServerEndpoint('https://core.test'),accessToken:'a'*32,refreshToken:'r'*32,expiresAt:DateTime.utc(2030),user:const ServerUser(id:'one',username:'Synthetic',role:ServerRole.admin,mustChangePassword:false),context:ServerContext.fromJson({'schemaVersion':1,'coreId':'a'*32,'homeId':'b'*32}));

BackupSnapshot restoreFixture([Map<String,dynamic>? settings]) => BackupSnapshot.fromJson({
  'version': 1, 'createdAt': '2026-09-06T00:00:00.000Z',
  'groups': {'settings': settings ?? {'appearance': 'light'}},
});
const restoreSettings = BackupSelection(settings: true, dashboard: false, connections: false);

Future<PreparedBackupRestore> prepare(BackupRepository repo, TestRestoreAccess access, [BackupSnapshot? snapshot]) => repo.prepareRestore(
  snapshot ?? restoreFixture(), restoreSettings,
  conflictPolicy: BackupConflictPolicy.replaceSelected, access: access,
);
Future<void> apply(PreparedBackupRestore prepared, {void Function()? afterClaim}) => ConfigurationWrites.run(() async {
  final boundary = Object();
  prepared.claimForHandoff(boundary);
  afterClaim?.call();
  await prepared.applyAfterHandoff(boundary, isCurrentBoundary: () => true);
});

void main() {
  test('prepared restore reads without effects then survives intended owner unmount exactly once', () async {
    final storage = MemoryBackupStorage(preferences: {'appearance':'dark'}), access = TestRestoreAccess();
    final prepared = await prepare(BackupRepository(storage: storage), access);
    expect(storage.writes, isEmpty);
    await apply(prepared, afterClaim: () => access.live = false);
    expect(storage.preferences['appearance'], 'light');
    expect(storage.secrets.keys.where((key) => key.startsWith('backup_restore_journal')), isEmpty);
    final writes = storage.writeCount;
    await expectLater(apply(prepared), throwsA(isA<BackupException>()));
    expect(storage.writeCount, writes);
  });
  test('target change after preparation rejects without journal or field mutation', () async {
    final storage = MemoryBackupStorage(preferences: {'appearance':'dark'});
    final prepared = await prepare(BackupRepository(storage: storage), TestRestoreAccess());
    storage.preferences['appearance'] = 'system';
    await expectLater(apply(prepared), throwsA(isA<BackupException>()));
    expect(storage.writes, isEmpty);
    expect(storage.preferences['appearance'], 'system');
  });
  for (final change in ['live','durable','retired','wrongBoundary']) {
    test('expired $change preparation cannot mutate storage', () async {
      final storage = MemoryBackupStorage(), access = TestRestoreAccess();
      final prepared = await prepare(BackupRepository(storage: storage), access);
      if (change=='live') access.live=false;
      if (change=='durable') access.durable=false;
      if (change=='retired') prepared.retire();
      await expectLater(change=='wrongBoundary' ? prepared.applyAfterHandoff(Object(), isCurrentBoundary:()=>true) : apply(prepared), throwsA(isA<BackupException>()));
      expect(storage.writes, isEmpty);
    });
  }
  test('Core source rejects Direct-bearing settings rather than silently retargeting', () async {
    final storage = MemoryBackupStorage(), access = TestRestoreAccess()..source=HomeSource.verifiedCore;
    await expectLater(prepare(BackupRepository(storage: storage), access, restoreFixture({'enabled_services': ['sonarr']})), throwsA(isA<BackupException>()));
    expect(storage.writes, isEmpty);
  });
  test('Core may explicitly restore device preferences without touching either layout or auth', () async {
    final storage = MemoryBackupStorage(preferences: {'dashboard_layout':'private', 'dashboard_layout_core_v1_fixture':'core','home_source_v1':'verifiedCore'}, secrets:{'larenor_server_session_v1':coreSession().encodeStorage(),'settings_pin':'private-pin'});
    final before = jsonEncode([storage.preferences,storage.secrets]);
    final access = TestRestoreAccess()..source=HomeSource.verifiedCore;
    final prepared = await prepare(BackupRepository(storage: storage), access);
    await apply(prepared);
    expect(storage.preferences.remove('appearance'), 'light');
    expect(jsonEncode([storage.preferences,storage.secrets]), before);
  });
}
