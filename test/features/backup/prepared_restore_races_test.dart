import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'backup_test_storage.dart';
import 'prepared_restore_test.dart' as fixtures;

const journalKey='backup_restore_journal_v2';
class _Storage extends MemoryBackupStorage {
  _Storage():super(preferences:{'appearance':'dark','keep_screen_on':false});
  void Function(String)? afterRead,afterWrite;
  @override Future<Object?> readPreference(String key) async { final value=await super.readPreference(key);afterRead?.call(key);return value; }
  @override Future<void> writePreference(String key,Object? value) async { await super.writePreference(key,value);afterWrite?.call(key); }
}
class _AliasedSnapshot implements BackupSnapshot {
  _AliasedSnapshot(this.json);
  final Map<String,dynamic> json;
  @override Map<String,dynamic> toJson()=>json;
  @override DateTime get createdAt=>DateTime.parse(json['createdAt'] as String);
  @override bool get hasSettings=>true;
  @override bool get hasDashboard=>false;
  @override bool get hasConnections=>false;
}
void main() {
  test('owner retirement in awaited before-read produces zero forward field effects', () async {
    final storage=_Storage(), access=fixtures.TestRestoreAccess();
    final prepared=await fixtures.prepare(BackupRepository(storage:storage),access);
    storage.afterRead=(key) { if(key=='appearance' && storage.secrets.containsKey(journalKey)) access.durable=false; };
    await expectLater(fixtures.apply(prepared),throwsA(isA<BackupException>()));
    expect(storage.writes.where((key)=>key=='pref:appearance'),isEmpty);
    expect(storage.preferences['appearance'],'dark');
  });
  test('changed earlier target cannot be marked committed after a later field await', () async {
    final storage=_Storage();
    final prepared=await fixtures.prepare(BackupRepository(storage:storage),fixtures.TestRestoreAccess(),fixtures.restoreFixture({'appearance':'light','keep_screen_on':true}));
    storage.afterWrite=(key) { if(key=='keep_screen_on') storage.preferences['appearance']='system'; };
    await expectLater(fixtures.apply(prepared),throwsA(isA<BackupException>()));
    expect(storage.preferences['appearance'],'system');
    final journal=jsonDecode(storage.secrets[journalKey]!) as Map;
    expect(journal['phase'],'applying');
    expect(storage.durableImages.map((image)=>image.secrets[journalKey]).whereType<String>().map((raw)=>(jsonDecode(raw) as Map)['phase']),isNot(contains('committed')));
  });
  test('nested incoming alias cannot change approved values after preparation', () async {
    final values=<String>['sonarr'];
    final snapshot=_AliasedSnapshot({'version':1,'createdAt':'2026-09-06T00:00:00.000Z','groups':{'settings':{'enabled_services':values}}});
    final storage=_Storage();
    final prepared=await fixtures.prepare(BackupRepository(storage:storage),fixtures.TestRestoreAccess(),snapshot);
    values.add('radarr');
    await fixtures.apply(prepared);
    expect(storage.preferences['enabled_services'],['sonarr']);
  });
  test('recovery cannot delete a replacement journal observed after target read', () async {
    final initial=_Storage();
    await fixtures.apply(await fixtures.prepare(BackupRepository(storage:initial),fixtures.TestRestoreAccess()));
    final committed=initial.durableImages.firstWhere((image)=>image.secrets[journalKey]!=null && (jsonDecode(image.secrets[journalKey]!) as Map)['phase']=='committed');
    final storage=_Storage();storage.preferences..clear()..addAll(committed.preferences);storage.secrets.addAll(committed.secrets);
    storage.afterRead=(key) {if(key=='appearance') storage.secrets[journalKey]='replacement-private-journal';};
    await expectLater(BackupRepository(storage:storage).recoverPendingRestore(),throwsA(isA<BackupException>()));
    expect(storage.secrets[journalKey],'replacement-private-journal');
    expect(storage.writes,isEmpty);
  });
}
