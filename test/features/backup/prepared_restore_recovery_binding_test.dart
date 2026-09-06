import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'backup_test_storage.dart';
import 'prepared_restore_test.dart' as f;

const journal='backup_restore_journal_v2';
ServerSession session() => ServerSession(endpoint:ServerEndpoint('https://core.test'),accessToken:'a'*32,refreshToken:'r'*32,expiresAt:DateTime.utc(2030),user:const ServerUser(id:'one',username:'Synthetic',role:ServerRole.admin,mustChangePassword:false),context:ServerContext.fromJson({'schemaVersion':1,'coreId':'a'*32,'homeId':'b'*32}));
class CoreAccess extends f.TestRestoreAccess {
  CoreAccess(){source=HomeSource.verifiedCore;}
  @override Map<String,dynamic> get ownership=>{'source':source.name,'scope':{'coreId':'a'*32,'homeId':'b'*32,'userId':'one'}};
}
Future<List<MemoryBackupStorage>> images({bool core=false,bool home=true,bool ha=false}) async {
  final storage=MemoryBackupStorage(preferences:{'appearance':'dark','enabled_services':<String>[],if(core) SharedPreferencesHomeSourceStore.key:'verifiedCore'},secrets:{'ha_base_url':'https://a.test','ha_token':'old-origin',if(core) SecureServerSessionStore.key:session().encodeStorage()});
  final snapshot=ha ? BackupSnapshot.fromJson({'version':1,'createdAt':'2026-09-06T00:00:00Z','groups':{'connections':{'ha':{'baseUrl':'https://new.test','token':'approved-token'}}}}) : f.restoreFixture(home ? {'enabled_services':['sonarr']} : null);
  final prepared=await BackupRepository(storage:storage).prepareRestore(snapshot,BackupSelection(settings:!ha,dashboard:false,connections:ha),conflictPolicy:BackupConflictPolicy.replaceSelected,access:core ? CoreAccess() : f.TestRestoreAccess());
  await f.apply(prepared);
  return storage.durableImages.where((v)=>v.secrets[journal]!=null).toList();
}
MemoryBackupStorage phase(List<MemoryBackupStorage> values,String phase) => values.lastWhere((v)=>(jsonDecode(v.secrets[journal]!) as Map)['phase']==phase);
Future<void> unchanged(MemoryBackupStorage image)async {
  final before=jsonEncode([image.preferences,image.secrets]);
  await expectLater(BackupRepository(storage:image).recoverPendingRestore(),throwsA(isA<BackupException>()));
  expect(jsonEncode([image.preferences,image.secrets]),before);expect(image.writes,isEmpty);
}
void main(){
  for(final state in ['applying','committed']) {
    test('boot $state Direct home intent cannot cross HA origin A to B',()async {
      final image=phase(await images(),state);
      image.secrets..['ha_base_url']='https://b.test'..['ha_token']='new-origin';
      await unchanged(image);
    });
  }
  test('boot device intent cannot cross selected source Direct to Core',()async {
    final image=phase(await images(home:false),'applying');
    image.preferences[SharedPreferencesHomeSourceStore.key]='verifiedCore';
    image.secrets[SecureServerSessionStore.key]=session().encodeStorage();
    await unchanged(image);
  });
  for(final change in ['missing','pending','expired','user','context','token']) {
    test('boot Core device recovery preserves intent after $change session',()async {
      final image=phase(await images(core:true,home:false),'applying');
      final value=jsonDecode(session().encodeStorage()) as Map<String,dynamic>;
      switch(change) {
        case 'missing':image.secrets.remove(SecureServerSessionStore.key);
        case 'pending':value['authMutationPending']=true;
        case 'expired':value['expiresAt']='2020-01-01T00:00:00Z';
        case 'user':(value['user'] as Map)['id']='two';
        case 'context':(value['context'] as Map)['homeId']='c'*32;
        case 'token':value['accessToken']='z'*32;
      }
      if(change!='missing')image.secrets[SecureServerSessionStore.key]=jsonEncode(value);
      await unchanged(image);
    });
  }
  test('unchanged Core context recovers device data and never reads Direct secrets',()async {
    final image=phase(await images(core:true,home:false),'applying');
    expect(await BackupRepository(storage:image).recoverPendingRestore(),isTrue);
    expect(image.preferences['appearance'],'dark');
    expect(image.reads.where((v)=>v.contains('ha_token')||v.contains('ha_base_url')),isEmpty);
    expect(image.secrets[SecureServerSessionStore.key],session().encodeStorage());
  });
  test('Direct device recovery ignores changed HA origin and never reads session or HA',()async {
    final image=phase(await images(home:false),'applying');image.secrets['ha_token']='elsewhere';
    expect(await BackupRepository(storage:image).recoverPendingRestore(),isTrue);
    expect(image.reads.where((v)=>v.contains('ha_token')||v.contains('ha_base_url')||v.contains(SecureServerSessionStore.key)),isEmpty);
  });
  test('every approved HA tuple prefix crash can recover to complete before',()async {
    for(final image in await images(ha:true)) {
      final committed=(jsonDecode(image.secrets[journal]!) as Map)['phase']=='committed';
      expect(await BackupRepository(storage:image).recoverPendingRestore(),isTrue);
      expect(image.secrets['ha_base_url'],committed?'https://new.test':'https://a.test');
      expect(image.secrets['ha_token'],committed?'approved-token':'old-origin');
    }
  });
  test('HA before URL with after token is not an approved forward-write prefix',()async {
    final image=(await images(ha:true)).first;
    image.secrets['ha_token']='approved-token';
    await unchanged(image);
  });
}
