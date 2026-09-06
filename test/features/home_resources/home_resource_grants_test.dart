import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/data/home_resource_grants_api.dart';
import 'package:larenor/features/home_resources/domain/home_resource_grants.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

Map<String, dynamic> fixture() => jsonDecode(File('contracts/home-resource-grants.v1.json').readAsStringSync()) as Map<String,dynamic>;
Map<String, dynamic> copy(Object? value) => jsonDecode(jsonEncode(value)) as Map<String,dynamic>;
final badResponse = isA<LarenorServerException>().having((e) => e.code, 'code', 'invalid_response');
final badRequest = isA<LarenorServerException>().having((e) => e.code, 'code', 'invalid_request');

void main() {
  final f = fixture();
  final context = ServerContext.fromJson(f['context']);
  final target = HomeResourceRecord.fromJson(f['target'], expectedContext: context);
  HomeResourceGrants snapshot([String step='empty']) => HomeResourceGrants.fromJson(f[step]['response'], target: target);

  test('actual HTTP lifecycle preserves revisions, no-op and revocation', () async {
    final steps = ['empty','readOnly','readOnlyNoop','secondReadWrite','upgrade','revoke','revokeNoop'];
    var calls=0;
    final transport=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((request) async {
      final step=f[steps[calls++]];
      expect(request.method,step['method']);
      expect(request.url.path,'/api/v1${step['path']}');
      expect(request.url.query,isEmpty);
      expect(request.headers['authorization'],'Bearer synthetic-only');
      if (step['body']==null) {expect(request.body,isEmpty);} else {expect(jsonDecode(request.body),step['body']);}
      return http.Response(jsonEncode(step['response']),step['status'],headers:{'content-type':'application/json'});
    }));
    addTearDown(transport.close);
    final api=HomeResourceGrantsApi(transport,'synthetic-only',context);
    var current=await api.read(target);
    expect(current.grants,isEmpty);
    for(final step in steps.skip(1)) {
      final desired=f[step]['body']['permissions'];
      final access=desired['write']==true ? HomeResourcePermission.readWrite : desired['read']==true ? HomeResourcePermission.readOnly : HomeResourcePermission.none;
      current=await api.set(current,subjectId:(f[step]['path'] as String).split('/').last,permission:access);
      expect(current.aclRevision,f[step]['response']['grant']['aclRevision']);
    }
    expect(current.grants,{'2'*32:HomeResourcePermission.readWrite});
    expect(current.aclRevision,5);
    expect(calls,7);
    expect('$api$current',isNot(contains('synthetic-only')));
  });

  test('read may advance the ACL beyond the metadata row but never roll back', () {
    final actual=snapshot('sorted');
    expect(actual.aclRevision,3);
    expect(actual.grants.keys,['2'*32,'3'*32]);
    expect(()=>actual.grants['4'*32]=HomeResourcePermission.readOnly,throwsUnsupportedError);
    final newer=copy(f['target'])..['aclRevision']=4;
    final row=HomeResourceRecord.fromJson(newer,expectedContext:context);
    expect(()=>HomeResourceGrants.fromJson(f['sorted']['response'],target:row),throwsA(badResponse));
  });

  final listMutations=<String,void Function(Map<String,dynamic>)>{
    'unknown field':(v)=>v['extra']=true,
    'missing revision':(v)=>v.remove('aclRevision'),
    'boolean revision':(v)=>v['aclRevision']=true,
    'float revision':(v)=>v['aclRevision']=3.0,
    'zero revision':(v)=>v['aclRevision']=0,
    'grants map':(v)=>v['grants']={},
    'duplicate subject':(v)=>(v['grants'] as List).add(copy(v['grants'][0])),
    'unsorted subjects':(v)=>v['grants']=(v['grants'] as List).reversed.toList(),
    'too many grants':(v)=>v['grants']=List.filled(129,v['grants'][0]),
    'unknown grant field':(v)=>v['grants'][0]['extra']=true,
    'missing subject':(v)=>v['grants'][0].remove('subjectId'),
    'invalid subject':(v)=>v['grants'][0]['subjectId']='private/path',
    'cross core':(v)=>v['grants'][0]['target']['coreId']='c'*32,
    'cross home':(v)=>v['grants'][0]['target']['homeId']='c'*32,
    'cross record':(v)=>v['grants'][0]['target']['id']='c'*32,
    'wrong kind':(v)=>v['grants'][0]['target']['kind']='resource',
    'float schema':(v)=>v['grants'][0]['target']['schemaVersion']=1.0,
    'extra ref':(v)=>v['grants'][0]['target']['extra']=true,
    'different revision':(v)=>v['grants'][0]['aclRevision']=2,
    'wrong permissions type':(v)=>v['grants'][0]['permissions']='private',
    'numeric read':(v)=>v['grants'][0]['permissions']['read']=1,
    'unknown permission':(v)=>v['grants'][0]['permissions']['admin']=true,
    'write without read':(v)=>v['grants'][0]['permissions']={'read':false,'write':true},
    'revoked member in stored list':(v)=>v['grants'][0]['permissions']={'read':false,'write':false},
  };
  for(final item in listMutations.entries) {
    test('strict grant list rejects ${item.key}',() {
      final value=copy(f['sorted']['response']);item.value(value);
      expect(()=>HomeResourceGrants.fromJson(value,target:target),throwsA(badResponse));
    });
  }

  final responseMutations=<String,void Function(Map<String,dynamic>)>{
    'wrong subject':(v)=>v['grant']['subjectId']='2'*32,
    'wrong target':(v)=>v['grant']['target']['id']='2'*32,
    'wrong permission':(v)=>v['grant']['permissions']['write']=true,
    'stale revision':(v)=>v['grant']['aclRevision']=1,
    'jumping revision':(v)=>v['grant']['aclRevision']=3,
    'extra response':(v)=>v['extra']=true,
    'missing grant':(v)=>v.remove('grant'),
  };
  for(final item in responseMutations.entries) {
    test('mutation response binds ${item.key}',() {
      final value=copy(f['readOnly']['response']);item.value(value);
      expect(()=>snapshot().withUpdatedGrant(value,subjectId:'3'*32,permission:HomeResourcePermission.readOnly),throwsA(badResponse));
    });
  }

  for(final subject in ['', '3'*31, 'G'*32, '${'3'*32}\n', '../private']) {
    test('invalid subject ${subject.length} never sends HTTP',() async {
      var calls=0;
      final transport=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((_) async {calls++;return http.Response('{}',200);}));
      addTearDown(transport.close);
      await expectLater(HomeResourceGrantsApi(transport,'synthetic',context).set(snapshot(),subjectId:subject,permission:HomeResourcePermission.readOnly),throwsA(badRequest));
      expect(calls,0);
    });
  }

  for(final step in ['memberCannotList','memberCannotGrant','stale','writeRequiresRead']) {
    test('actual $step response is rejected without retry',() async {
      var calls=0;
      final transport=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((_) async {
        calls++;
        return http.Response(jsonEncode(f[step]['response']),f[step]['status'],headers:{'content-type':'application/json'});
      }));
      addTearDown(transport.close);
      final api=HomeResourceGrantsApi(transport,'synthetic',context);
      await expectLater(step=='memberCannotList' ? api.read(target) : api.set(snapshot(),subjectId:'3'*32,permission:HomeResourcePermission.readOnly),throwsA(isA<LarenorServerException>()));
      expect(calls,1);
    });
  }

  for(final field in ['coreId','homeId']) {
    test('different $field cannot read or mutate this snapshot',() async {
      final other=copy(f['context'])..[field]='c'*32;
      var calls=0;
      final transport=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((_) async {calls++;return http.Response('{}',200);}));
      addTearDown(transport.close);
      final api=HomeResourceGrantsApi(transport,'synthetic',ServerContext.fromJson(other));
      await expectLater(api.read(target),throwsA(badRequest));
      await expectLater(api.set(snapshot(),subjectId:'3'*32,permission:HomeResourcePermission.readOnly),throwsA(badRequest));
      expect(calls,0);
    });
  }

  test('revision exhaustion stops a changed grant before HTTP but permits no-op',() async {
    const maximum=9223372036854775807;
    final raw=copy(f['empty']['response'])..['aclRevision']=maximum;
    final current=HomeResourceGrants.fromJson(raw,target:target);
    var calls=0;
    final transport=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((_) async {
      calls++;
      final reply=copy(f['revoke']['response']);reply['grant']['aclRevision']=maximum;
      return http.Response(jsonEncode(reply),200,headers:{'content-type':'application/json'});
    }));
    addTearDown(transport.close);
    final api=HomeResourceGrantsApi(transport,'synthetic',context);
    await expectLater(api.set(current,subjectId:'3'*32,permission:HomeResourcePermission.readOnly),throwsA(isA<LarenorServerException>().having((e)=>e.code,'code','revision_conflict')));
    expect(calls,0);
    final unchanged=await api.set(current,subjectId:'3'*32,permission:HomeResourcePermission.none);
    expect(unchanged.aclRevision,maximum);
    expect(calls,1);
  });

  test('closed in-flight mutation rejects late result and never resends',() async {
    var calls=0;
    final sent=Completer<void>(), reply=Completer<http.Response>();
    final transport=LarenorServerApi(endpoint:ServerEndpoint('https://synthetic.invalid'),client:MockClient((_) async {calls++;sent.complete();return reply.future;}));
    addTearDown(transport.close);
    final result=HomeResourceGrantsApi(transport,'synthetic',context).set(snapshot(),subjectId:'3'*32,permission:HomeResourcePermission.readOnly);
    final checked=expectLater(result,throwsA(isA<LarenorServerException>().having((e)=>e.code,'code','cancelled')));
    await sent.future.timeout(const Duration(seconds:5));
    transport.close();
    reply.complete(http.Response(jsonEncode(f['readOnly']['response']),200,headers:{'content-type':'application/json'}));
    await checked;
    expect(calls,1);
  });
}
