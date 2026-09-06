import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/home_resource_grants_contract_fixture.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_resource_grants.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  late SyntheticHaServer host;
  late SyntheticCoreAccount core;
  late HttpClient client;
  final contract =
      jsonDecode(homeResourceGrantsContractFixture) as Map<String, dynamic>;
  Future<(int, Object?)> request(
    String method,
    String path, {
    Object? body,
    bool authorized = true,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('${host.baseUrl}/api/v1$path'),
    );
    if (authorized) {
      req.headers.set('authorization', 'Bearer ${core.currentAccessToken}');
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  setUp(() async {
    host = await SyntheticHaServer.start();
    core = SyntheticCoreAccount(grants: SyntheticCoreResourceGrants());
    host.coreAccount = core;
    client = FixtureNetwork(host.port).createHttpClient(null);
    expect(
      (await request(
        'POST',
        '/auth/login',
        body: {
          'username': SyntheticCoreAccount.username,
          'password': SyntheticCoreAccount.password,
          'deviceName': 'fixture',
        },
      )).$1,
      200,
    );
  });
  tearDown(() async {
    client.close(force: true);
    await host.close();
  });
  test('bundled grants fixture equals actual Server HTTP contract', () {
    expect(
      contract,
      jsonDecode(
        File('contracts/home-resource-grants.v1.json').readAsStringSync(),
      ),
    );
  });
  test('logout journey target resolves through the actual authenticated resource route', () async {
    final id = core.grants!.targetId;
    final (status, body) = await request(
      'GET',
      '/home-resources/${core.coreId}/${core.homeId}/$id',
    );
    expect(status, 200);
    expect((body as Map)['record'], contract['target']);
    expect(core.grants!.recordReads, 1);
    expect(core.grants!.mutations, isEmpty);
    expect(host.requests, 0);
    expect(host.acceptedActions, isEmpty);
  });
  test('authenticated ACL mode returns named existing Core users', () async {
    final (status, raw) = await request('GET', '/admin/users');
    expect(status, 200);
    final users = (raw as Map)['users'] as List;
    expect(
      users.map((u) => u['id']),
      containsAll(['2' * 32, '3' * 32, '9' * 32]),
    );
    expect(host.requests, 0);
    expect(host.acceptedActions, isEmpty);
  });
  test('real HTTP follows exact ACL contract including no-op, revoke and stale revision', () async {
    for (final name in [
      'empty',
      'readOnly',
      'afterReadOnly',
      'readOnlyNoop',
      'secondReadWrite',
      'sorted',
      'upgrade',
      'revoke',
      'revokeNoop',
      'afterRevoke',
      'stale',
      'writeRequiresRead',
    ]) {
      final step = contract[name] as Map;
      final (status, body) = await request(
        step['method'] as String,
        step['path'] as String,
        body: step['body'],
      );
      expect(status, step['status'], reason: name);
      expect(body, step['response'], reason: name);
    }
    expect(host.requests, 0);
    expect(host.acceptedActions, isEmpty);
  });
}
