import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'backup_test_storage.dart';
import 'prepared_restore_test.dart' as f;

const _key='backup_restore_journal_v2';
class _Faults extends MemoryBackupStorage {
  _Faults():super(preferences:{'appearance':'dark','keep_screen_on':false});
  bool loseApplying=false,loseCommitted=false,loseDelete=false;
  @override Future<void> writeSecret(String key,String? value) async {
    await super.writeSecret(key,value);
    if(key!=_key) return;
    if(value==null && loseDelete || value!=null &&
      ((jsonDecode(value) as Map)['phase']=='applying' && loseApplying ||
       (jsonDecode(value) as Map)['phase']=='committed' && loseCommitted)) {
      throw StateError('private-response-lost');
    }
  }
}
Future<void> _run(MemoryBackupStorage storage) async => f.apply(await f.prepare(BackupRepository(storage:storage),f.TestRestoreAccess(),f.restoreFixture({'appearance':'light','keep_screen_on':true})));
void main() {
  test('every durable crash image recovers exactly before or committed after', () async {
    final storage=_Faults();await _run(storage);
    expect(storage.durableImages.length,5);
    for(final image in storage.durableImages) {
      final raw=image.secrets[_key];
      final phase=raw==null ? 'complete' : (jsonDecode(raw) as Map)['phase'];
      final result=await BackupRepository(storage:image).recoverPendingRestore();
      expect(result,raw!=null);
      expect(image.preferences,phase=='applying' ? {'appearance':'dark','keep_screen_on':false} : {'appearance':'light','keep_screen_on':true});
      expect(image.secrets,isEmpty);
    }
  });
  for(final phase in ['committed','delete']) {
    test('lost $phase acknowledgement uses durable phase without double effects',() async {
      final storage=_Faults()..loseCommitted=phase=='committed'..loseDelete=phase=='delete';
      await _run(storage);
      expect(storage.preferences,{'appearance':'light','keep_screen_on':true});
      expect(storage.writes.where((v)=>v.startsWith('pref:')),['pref:appearance','pref:keep_screen_on']);
      expect(storage.secrets,isEmpty);
    });
  }
  test('lost initial journal ACK leaves zero field effects and recoverable intent', () async {
    final storage=_Faults()..loseApplying=true;
    await expectLater(_run(storage),throwsA(isA<BackupException>()));
    expect(storage.writes.where((v)=>v.startsWith('pref:')),isEmpty);
    expect(storage.secrets,contains(_key));
    expect(await BackupRepository(storage:storage).recoverPendingRestore(),isTrue);
    expect(storage.preferences,{'appearance':'dark','keep_screen_on':false});
  });
  test('foreign third value preserves journal and every target', () async {
    final initial=_Faults();await _run(initial);
    final image=initial.durableImages.firstWhere((i)=>i.preferences['keep_screen_on']==true && i.secrets[_key]!=null);
    image.preferences['appearance']='system';
    final raw=image.secrets[_key];
    await expectLater(BackupRepository(storage:image).recoverPendingRestore(),throwsA(isA<BackupException>()));
    expect(image.preferences,{'appearance':'system','keep_screen_on':true});
    expect(image.secrets[_key],raw);expect(image.writes,isEmpty);
  });
  for(final malformed in ['{}','private broken json','{"version":2}','null']) {
    test('malformed journal is preserved and never exposes raw content $malformed', () async {
      final storage=MemoryBackupStorage(secrets:{_key:malformed});
      await expectLater(BackupRepository(storage:storage).recoverPendingRestore(),throwsA(isA<BackupException>().having((e)=>e.toString(),'static',isNot(contains('private broken')))));
      expect(storage.secrets[_key],malformed);expect(storage.writes,isEmpty);
    });
  }
  test('concurrent legacy and prepared journals require explicit unresolved recovery',() async {
    final storage=_Faults()..loseApplying=true;
    await expectLater(_run(storage),throwsA(isA<BackupException>()));
    storage.secrets[BackupRepository.restoreJournalKey]='legacy-unresolved';
    final before=Map.of(storage.secrets);storage.writes.clear();
    await expectLater(BackupRepository(storage:storage).recoverPendingRestore(),throwsA(isA<BackupException>()));
    expect(storage.secrets,before);expect(storage.writes,isEmpty);
  });
}
