import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_people/data/home_people_api.dart';
import 'package:larenor/features/home_people/domain/home_person_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_person_models_test.dart' show fixture, copy, failure;

http.Response response(Object? value, [int status=200]) => status==204 ? http.Response('',204) : http.Response(jsonEncode(value),status,headers:{'content-type':'application/json'});

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async {value=session;}
}
final class _AuthApi extends LarenorServerApi {
  _AuthApi(this.value) : super(endpoint:value.endpoint, client:MockClient((_) async=>response(null,500)));
  final ServerSession value;
  @override
  Future<ServerUser> me(String token) async => value.user;
  @override
  Future<ServerContext> context(String token) async => value.context!;
  @override
  Future<void> logout(ServerSession session) async {}
}

void main() {
  final f=fixture();
  final context=ServerContext.fromJson(f['context']);
  final public='/home-people/${context.coreId}/${context.homeId}';
  final admin='/admin$public';
  final subject=f['subjectId'] as String;
  HomePersonRecord target([String step='createPerson']) => HomePersonRecord.fromJson(f[step]['response']['person'],expectedContext:context);
  HomePeopleApi apiWith(http.Client client, {bool Function()? current}) {
    final transport=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid/prefix'),client:client);
    addTearDown(transport.close);
    return HomePeopleApi(transport,'synthetic_token',context,isCurrent:current??()=>true);
  }
  test('actual authenticated fixture matches read/admin CRUD and grant transport',() async {
    String step='emptyList';
    var calls=0;
    final api=apiWith(MockClient((request) async {
      calls++;
      final expected=f[step];
      expect(request.method,expected['method']);
      expect(request.url.path,'/prefix/api/v1${expected['path']}');
      expect(request.url.queryParameters,expected['query']);
      expect(request.body.isEmpty?null:jsonDecode(request.body),expected['body']);
      expect(request.headers['authorization'],'Bearer synthetic_token');
      expect(request.followRedirects,isFalse);
      return response(expected['response'],expected['status'] as int);
    }));
    expect((await api.list()).entries,isEmpty);
    step='createPerson';
    var record=await api.create(label:f[step]['body']['label'] as String,order:7);
    expect(record.id,'1'*32);
    step='createUnicode';
    expect((await api.create(label:'🌿'*80,order:10000)).id,'2'*32);
    step='beforeUpdate';
    record=await api.get(record.id);
    expect(record.aclRevision,2);
    step='firstPage';
    final page=await api.list(limit:1);
    step='secondPage';
    expect((await api.list(limit:1,after:page.nextAfter,snapshot:page.snapshot)).nextAfter,isNull);
    step='updatePerson';
    record=await api.update(record,label:'Ece Öztürk',order:0);
    expect(record.revision,2);
    step='noopPerson';
    record=await api.update(record,label:'Ece Öztürk',order:0);
    expect(record.revision,2);
    step='grantsAfterRead';
    var grants=await api.grants(record);
    expect(grants.aclRevision,2);
    for (final pair in [('grantWrite',HomePersonPermission.readWrite),('grantNoop',HomePersonPermission.readWrite),('revoke',HomePersonPermission.none)]) {
      step=pair.$1;
      grants=await api.setGrant(grants,subjectId:subject,permission:pair.$2);
    }
    step='beforeDelete';
    record=await api.get(record.id);
    step='deletePerson';
    await api.delete(record);
    expect(calls,14);
    expect(api.toString(),'HomePeopleApi');
  });
  test('foreign context targets and malformed arguments dispatch zero requests',() async {
    var calls=0;
    final api=apiWith(MockClient((_) async {calls++; return response(null);}));
    final other=ServerContext.fromJson(f['otherContextList']['response']['scope']);
    final foreign=HomePersonRecord.fromJson(f['otherContextList']['response']['entries'][0],expectedContext:other);
    await expectLater(api.update(foreign,label:'Foreign',order:0),throwsA(failure('invalid_request')));
    await expectLater(api.delete(foreign),throwsA(failure('invalid_request')));
    await expectLater(api.grants(foreign),throwsA(failure('invalid_request')));
    await expectLater(api.get('../foreign'),throwsA(failure('invalid_request')));
    await expectLater(api.create(label:'x'*81,order:0),throwsA(failure('invalid_request')));
    await expectLater(api.create(label:'Good',order:-1),throwsA(failure('invalid_request')));
    final grants=HomePersonGrants.fromJson(f['emptyGrants']['response'],target:target());
    await expectLater(api.setGrant(grants,subjectId:'invalid',permission:HomePersonPermission.readOnly),throwsA(failure('invalid_request')));
    expect(calls,0);
  });
  for(final status in [200,401,503]) {
    test('retired adapter discards late $status and never retries',() async {
      final pending=Completer<http.Response>();
      var current=true,calls=0;
      final api=apiWith(MockClient((_) {calls++;return pending.future;}),current:()=>current);
      final result=api.list();
      final outcome=expectLater(result,throwsA(failure('cancelled')));
      await Future<void>.delayed(Duration.zero);
      current=false;
      pending.complete(response(status==200?f['adminList']['response']:{'error':{'code':'private_payload','message':'private_payload'}},status));
      await outcome;
      current=true;
      await expectLater(api.list(),throwsA(failure('cancelled')));
      expect(calls,1);
    });
  }
  test('explicit retire before dispatch and throwing lifetime hook are safe',() async {
    var calls=0;
    final api=apiWith(MockClient((_) async {calls++;return response(null);}));
    api.retire();
    await expectLater(api.list(),throwsA(failure('cancelled')));
    final broken=apiWith(MockClient((_) async {calls++;return response(null);}),current:()=>throw StateError('private'));
    await expectLater(broken.list(),throwsA(failure('cancelled')));
    expect(calls,0);
  });
  for(final status in [200,401]) {
    test('actual account logout retires pending people $status response',() async {
      final session=ServerSession(endpoint:ServerEndpoint('https://synthetic.invalid'),accessToken:'synthetic_access_1234567890',refreshToken:'synthetic_refresh_1234567890',expiresAt:DateTime.now().add(const Duration(days:1)),context:context,user:ServerUser(id:'e'*32,username:'Fixture',role:ServerRole.member,mustChangePassword:false));
      final store=_Store(session),auth=_AuthApi(session);
      final account=ServerAccountController(store:store,apiFactory:(_)=>auth);
      addTearDown(account.dispose);
      await account.initialize();
      final captured=account.session!,generation=account.generation;
      final pending=Completer<http.Response>();
      final api=apiWith(MockClient((_)=>pending.future),current:()=>account.isCurrent(generation)&&identical(account.session,captured)&&!account.working&&!account.hasPendingContext);
      final work=account.withSession((_,__)=>api.list());
      final outcome=expectLater(work,throwsA(failure('cancelled')));
      await Future<void>.delayed(Duration.zero);
      await account.signOut();
      pending.complete(response(status==200?f['adminList']['response']:{'error':{'code':'unauthorized'}},status));
      await outcome;
      expect(account.session,isNull);
      expect(store.value,isNull);
      expect(account.failure,isNull);
    });
  }
  test('active unauthorized and generic 503 remain typed without reflecting response text',() async {
    for(final (status,code) in [(401,'unauthorized'),(503,'server_error')]) {
      var calls=0;
      final api=apiWith(MockClient((_) async {calls++;return response({'error':{'code':'private_body','message':'private_body'}},status);}));
      await expectLater(api.list(),throwsA(failure(code)));
      expect(calls,1);
    }
  });
  for(final mode in ['unknown','foreign','oversized','oversized-error','wrong-create','wrong-update','nonempty-delete']) {
    test('strict transport rejects $mode body',() async {
      final data=copy(f['adminList']['response']);
      if(mode=='unknown') data['private']='value';
      if(mode=='foreign') data['scope']['homeId']='d'*32;
      final api=apiWith(MockClient((_) async {
        if(mode.startsWith('oversized')) return http.Response('x'*(mode=='oversized'?LarenorServerApi.maxJsonBytes+1:8193),mode=='oversized'?200:503);
        return response(data);
      }));
      final Future<Object?> call=switch(mode) {
        'wrong-create'=>api.create(label:'Deniz',order:0),
        'wrong-update'=>api.update(target(),label:'Deniz',order:0),
        'nonempty-delete'=>api.delete(target()),
        _=>api.list(),
      };
      await expectLater(call,throwsA(failure('invalid_response')));
    });
  }
  test('person query allowlist is exact and rejects missing DELETE revisions',() async {
    var calls=0;
    final transport=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((_) async {calls++;return response(null);}));
    addTearDown(transport.close);
    for(final (method,path,query) in <(String,String,Map<String,String>?)>[
      ('GET',public,{'after':'1'*32}),
      ('GET',public,{'limit':'01'}),('GET',public,{'limit':'101'}),
      ('GET',public,{'expectedSnapshot':'bad'}),('GET',public,{'userId':'e'*32}),
      ('GET','$public/${'1'*32}',{'limit':'1'}),
      ('GET','$admin/${'1'*32}/grants',{'limit':'1'}),
      ('POST',public,{'limit':'1'}),
      ('DELETE','$admin/${'1'*32}',null),
      ('DELETE','$admin/${'1'*32}',{'expectedRevision':'1'}),
      ('DELETE','$admin/${'1'*32}',{'expectedRevision':'01','expectedAclRevision':'1'}),
      ('DELETE','$admin/${'1'*32}',{'expectedRevision':'1','expectedAclRevision':'0'}),
      ('DELETE','$admin/${'1'*32}',{'expectedRevision':'1','expectedAclRevision':'9223372036854775808'}),
      ('DELETE','$admin/${'1'*32}/grants',{'expectedRevision':'1','expectedAclRevision':'1'}),
    ]) {
      await expectLater(transport.request(method,path,queryParameters:query),throwsA(failure('invalid_request')));
    }
    expect(calls,0);
  });
}
