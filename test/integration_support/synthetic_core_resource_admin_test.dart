import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/home_resource_admin_contract_fixture.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_resource_admin.dart';
import '../../integration_test/support/synthetic_core_resources.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

class _Member extends SyntheticCoreAccount {
  _Member(SyntheticCoreResourceAdmin admin) : super(adminResources: admin);
  @override
  Map<String, Object?> get user => {...super.user, 'role': 'member'};
}

void main() {
  late SyntheticHaServer host;
  late SyntheticCoreResourceAdmin admin;
  late SyntheticCoreAccount core;
  late HttpClient client;
  final contract = jsonDecode(homeResourceAdminContractFixture) as Map<String, dynamic>;
  final create = contract['createRoom'] as Map<String, dynamic>;

  setUp(() async {
    host = await SyntheticHaServer.start();
    admin = SyntheticCoreResourceAdmin();
    core = SyntheticCoreAccount(adminResources: admin);
    host.coreAccount = core;
    client = FixtureNetwork(host.port).createHttpClient(null);
  });
  tearDown(() async { client.close(force: true); await host.close(); });

  Future<(int, Object?)> request(String method, String path, {
    Object? body, String? raw, bool authorized = true,
  }) async {
    final outgoing = await client.openUrl(method, Uri.parse('${host.baseUrl}/api/v1$path'));
    if (authorized) outgoing.headers.set('authorization', 'Bearer ${SyntheticCoreAccount.accessToken}');
    if (body != null || raw != null) {
      outgoing.headers.contentType = ContentType.json;
      outgoing.write(raw ?? jsonEncode(body));
    }
    final incoming = await outgoing.close();
    final text = await utf8.decodeStream(incoming);
    return (incoming.statusCode, text.isEmpty ? null : jsonDecode(text));
  }
  String listPath() => '/home-resources/${core.coreId}/${core.homeId}';

  test('bundled admin contract equals actual Server HTTP fixture', () {
    expect(contract, jsonDecode(File('contracts/home-resource-admin.v1.json').readAsStringSync()));
  });
  test('explicit admin creates exact contract record and fresh authenticated list', () async {
    expect((await request('GET', listPath())).$1, 200);
    expect((await request('POST', create['path'] as String, body: create['body'])).$1, 201);
    expect(admin.records.single, create['response']['record']);
    final (_, page) = await request('GET', listPath());
    expect((page as Map)['entries'], [create['response']['record']]);
    expect(admin.mutations, ['POST']);
    expect(admin.reads, 2);
    expect(host.requests, 0); expect(host.acceptedActions, isEmpty);
  });
  test('rename and order then exact delete are metadata only', () async {
    await request('POST', create['path'] as String, body: create['body']);
    final path='${create['path']}/${'1' * 32}';
    final (status, result)=await request('PATCH', path, body:{'label':'Renamed room','order':7,'expectedRevision':1,'expectedAclRevision':1});
    expect(status,200);expect((result as Map)['record']['revision'],2);expect(admin.records.single['order'],7);
    expect((await request('DELETE','$path?expectedRevision=2&expectedAclRevision=1')).$1,204);
    expect((await request('GET','${listPath()}/${'1' * 32}')).$1,404);
    expect(admin.records,isEmpty);expect(admin.mutations,['POST','PATCH','DELETE']);expect(host.requests,0);
  });
  test('unknown duplicate and stale write inputs never change records', () async {
    await request('POST', create['path'] as String, body: create['body']);
    final before=jsonEncode(admin.records);
    for(final raw in ['{"kind":"room","label":"A","label":"B","order":0}', '{"kind":"room","label":"A","order":0,"token":"private"}']) {
      expect((await request('POST',create['path'] as String,raw:raw)).$1,400);
    }
    final path='${create['path']}/${'1' * 32}';
    expect((await request('PATCH',path,body:{'label':'Stale','order':0,'expectedRevision':2,'expectedAclRevision':1})).$1,409);
    expect((await request('DELETE','$path?expectedRevision=1&expectedRevision=1&expectedAclRevision=1')).$1,400);
    expect(jsonEncode(admin.records),before);expect(admin.mutations,['POST']);expect(host.requests,0);
  });
  test('wrong auth scope and member role deny all metadata mutations', () async {
    expect((await request('POST',create['path'] as String,body:create['body'],authorized:false)).$1,401);
    expect((await request('POST','/admin/home-resources/${'c'*32}/${'d'*32}',body:create['body'])).$1,404);
    host.coreAccount=_Member(admin);
    expect((await request('POST',create['path'] as String,body:create['body'])).$1,403);
    expect(admin.records,isEmpty);expect(admin.mutations,isEmpty);expect(host.requests,0);
  });
  test('default and existing member fixtures never opt into admin writes', () async {
    for(final actor in [SyntheticCoreAccount(),SyntheticCoreAccount(resources:SyntheticCoreResources())]) {
      host.coreAccount=actor;
      expect((await request('POST',create['path'] as String,body:create['body'])).$1,403);
    }
    expect(admin.mutations,isEmpty);expect(host.requests,0);
    expect(()=>SyntheticCoreAccount(resources:SyntheticCoreResources(),adminResources:admin),throwsArgumentError);
  });
}
