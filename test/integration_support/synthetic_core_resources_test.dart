import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/home_resource_contract_fixture.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_resources.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  late SyntheticHaServer host;
  late SyntheticCoreResources resources;
  late SyntheticCoreAccount core;
  late HttpClient client;

  setUp(() async {
    host = await SyntheticHaServer.start();
    resources = SyntheticCoreResources();
    core = SyntheticCoreAccount(resources: resources);
    host.coreAccount = core;
    client = FixtureNetwork(host.port).createHttpClient(null);
  });
  tearDown(() async {
    client.close(force: true);
    await host.close();
  });

  Future<(int, Map<String, dynamic>)> get(
    String suffix, {
    String method = 'GET',
    bool authorized = true,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('${host.baseUrl}/api/v1$suffix'),
    );
    if (authorized) {
      request.headers.set(
        'authorization',
        'Bearer ${SyntheticCoreAccount.accessToken}',
      );
    }
    final response = await request.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>,
    );
  }

  String path() => '/home-resources/${core.coreId}/${core.homeId}';

  test(
    'Android fixture payload exactly matches actual Server HTTP contract',
    () {
      expect(
        jsonDecode(homeResourceContractFixture),
        jsonDecode(File('contracts/home-resources.v1.json').readAsStringSync()),
      );
    },
  );

  test('opt-in member list and pages use the actual shared responses', () async {
    final contract = jsonDecode(homeResourceContractFixture) as Map;
    expect(core.user['role'], 'member');
    expect(core.user['id'], 'e' * 32);
    expect((await get(path())).$2, contract['memberList']);
    final first = (await get('${path()}?limit=1')).$2;
    expect(first, contract['firstPage']);
    final second = await get(
      '${path()}?limit=1&after=${first['nextAfter']}&expectedSnapshot=${first['snapshot']}',
    );
    expect(second.$2, contract['secondPage']);
    expect(resources.reads, 3);
    expect(host.requests, 0);
    expect(host.acceptedActions, isEmpty);
  });

  test('revocation invalidates old pages and explicit empty view is bounded', () async {
    final first = (await get('${path()}?limit=1')).$2;
    resources.view = SyntheticCoreResourceView.revoked;
    final contract = jsonDecode(homeResourceContractFixture) as Map;
    expect((await get(path())).$2, contract['revokedList']);
    expect(
      (await get(
        '${path()}?limit=1&after=${first['nextAfter']}&expectedSnapshot=${first['snapshot']}',
      )).$1,
      409,
    );
    resources.view = SyntheticCoreResourceView.empty;
    expect((await get(path())).$2, contract['emptyList']);
    expect(host.requests, 0);
  });

  test(
    'other Core has only its own actual scope and rejects wrong paths',
    () async {
      final oldPath = path();
      core.coreId = 'c' * 32;
      core.homeId = 'd' * 32;
      final contract = jsonDecode(homeResourceContractFixture) as Map;
      expect((await get(path())).$2, contract['otherContextList']);
      expect((await get(oldPath)).$1, 404);
      expect(host.requests, 0);
    },
  );

  test(
    'fixture never exposes write, auth-free or unbounded query paths',
    () async {
      for (final suffix in [
        '?limit=0',
        '?limit=101',
        '?limit=1&limit=2',
        '?token=private',
        '?after=${'1' * 32}',
        '?limit=01',
        '?expectedSnapshot=${'g' * 64}',
      ]) {
        expect((await get('${path()}$suffix')).$1, 400);
      }
      expect((await get(path(), authorized: false)).$1, 401);
      expect((await get(path(), method: 'POST')).$1, 403);
      expect((await get('/admin${path()}', method: 'POST')).$1, 403);
      host.coreAccount = SyntheticCoreAccount();
      expect((await get(path())).$1, 403);
      expect(resources.reads, 0);
      expect(host.requests, 0);
      expect(host.acceptedActions, isEmpty);
    },
  );
}
