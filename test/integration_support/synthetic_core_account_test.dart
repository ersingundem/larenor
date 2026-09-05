import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  late SyntheticHaServer host;
  late SyntheticCoreAccount core;
  late HttpClient client;

  setUp(() async {
    host = await SyntheticHaServer.start();
    core = SyntheticCoreAccount();
    host.coreAccount = core;
    // Real sockets remain restricted to this test's exact loopback port.
    client = FixtureNetwork(host.port).createHttpClient(null);
  });
  tearDown(() async {
    client.close(force: true);
    await host.close();
  });

  Future<(int, Map<String, dynamic>)> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('${host.baseUrl}/api/v1$path'),
    );
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>,
    );
  }

  test('real loopback login and context remain separate from HA', () async {
    final (status, pair) = await request(
      'POST',
      '/auth/login',
      body: {
        'username': SyntheticCoreAccount.username,
        'password': SyntheticCoreAccount.password,
        'deviceName': 'Synthetic tablet',
      },
    );
    expect(status, 200);
    expect(pair['accessToken'], SyntheticCoreAccount.accessToken);
    final (meStatus, me) = await request(
      'GET',
      '/auth/me',
      token: pair['accessToken'] as String,
    );
    expect(meStatus, 200);
    expect(me['user'], pair['user']);
    final (contextStatus, context) = await request(
      'GET',
      '/context',
      token: pair['accessToken'] as String,
    );
    expect(contextStatus, 200);
    expect(context['coreId'], core.coreId);
    expect(context['homeId'], core.homeId);
    expect(host.reads, isEmpty);
    expect(host.requests, 0);
    expect(host.subscriptions, 0);
    expect(core.rejectedRequests, 0);
  });

  test('context is re-read after same-address Core replacement', () async {
    final (_, first) = await request(
      'GET',
      '/context',
      token: SyntheticCoreAccount.accessToken,
    );
    core.coreId = 'c' * 32;
    core.homeId = 'd' * 32;
    final (_, second) = await request(
      'GET',
      '/context',
      token: SyntheticCoreAccount.accessToken,
    );
    expect(first, isNot(second));
    expect(second['coreId'], core.coreId);
    expect(core.contextReads, 2);
  });

  String resourcesPath() => '/home-resources/${core.coreId}/${core.homeId}';

  test('default admin supports its visible empty Core list without rejection', () async {
    final originalUser = Map<String, Object?>.of(core.user);
    expect(originalUser['id'], 'fixture-core-user-id');
    expect(originalUser['role'], 'admin');
    final (status, body) = await request(
      'GET',
      '${resourcesPath()}?limit=25',
      token: SyntheticCoreAccount.accessToken,
    );
    expect(status, 200);
    final page = HomeResourcePage.fromJson(
      body,
      expectedContext: ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': core.coreId,
        'homeId': core.homeId,
      }),
    );
    expect(page.entries, isEmpty);
    expect(page.nextAfter, isNull);
    expect(core.user, originalUser);
    expect(core.resources, isNull);
    expect(core.rejectedRequests, 0);
    expect(host.requests, 0);
    expect(host.acceptedActions, isEmpty);
  });

  test('empty admin list follows current Core and rejects old scope and snapshot', () async {
    final oldPath = resourcesPath();
    final (_, first) = await request(
      'GET', oldPath, token: SyntheticCoreAccount.accessToken,
    );
    expect(first['snapshot'], isA<String>());
    core.coreId = 'c' * 32;
    core.homeId = 'd' * 32;
    final (status, second) = await request(
      'GET', resourcesPath(), token: SyntheticCoreAccount.accessToken,
    );
    expect(status, 200);
    final page = HomeResourcePage.fromJson(
      second,
      expectedContext: ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': core.coreId,
        'homeId': core.homeId,
      }),
    );
    expect(page.entries, isEmpty);
    expect(second['snapshot'], isNot(first['snapshot']));
    expect((await request('GET', oldPath,
      token: SyntheticCoreAccount.accessToken)).$1, 404);
    expect((await request('GET', '${resourcesPath()}?expectedSnapshot=${first['snapshot']}',
      token: SyntheticCoreAccount.accessToken)).$1, 409);
    expect((await request('GET', '${resourcesPath()}?expectedSnapshot=${second['snapshot']}',
      token: SyntheticCoreAccount.accessToken)).$2, second);
    expect((await request('GET', '${resourcesPath()}?after=${'1' * 32}&expectedSnapshot=${second['snapshot']}',
      token: SyntheticCoreAccount.accessToken)).$1, 404);
    expect(core.rejectedRequests, 3);
    expect(host.requests, 0);
  });

  test('default list keeps strict verb bearer path and query boundaries', () async {
    final path = resourcesPath();
    for (final suffix in [
      '?limit=0', '?limit=101', '?limit=01', '?limit=x',
      '?limit=1&limit=2', '?token=private', '?after=${'1' * 32}',
      '?expectedSnapshot=${'g' * 64}',
    ]) {
      expect((await request('GET', '$path$suffix',
        token: SyntheticCoreAccount.accessToken)).$1, 400);
    }
    expect((await request('GET', path)).$1, 401);
    expect((await request('GET', path, token: 'wrong')).$1, 401);
    for (final method in ['POST', 'PATCH', 'DELETE']) {
      expect((await request(method, path,
        token: SyntheticCoreAccount.accessToken)).$1, 403);
    }
    expect((await request('GET', '$path/extra',
      token: SyntheticCoreAccount.accessToken)).$1, 404);
    expect((await request('GET', '/admin$path',
      token: SyntheticCoreAccount.accessToken)).$1, 403);
    expect(core.rejectedRequests, 15);
    expect(host.requests, 0);
    expect(host.acceptedActions, isEmpty);
  });

  test('HA counter also detects a wrong-scope rejected read', () async {
    final request = await client.getUrl(
      Uri.parse('${host.baseUrl}/api/states'),
    );
    request.headers.set(
      'authorization',
      'Bearer ${SyntheticCoreAccount.accessToken}',
    );
    final response = await request.close();
    expect(response.statusCode, 401);
    await response.drain<void>();
    expect(host.reads, isEmpty);
    expect(host.rejectedLogins, 1);
    expect(host.requests, 1);
    expect(core.contextReads, 0);
  });

  test(
    'wrong credentials, arbitrary APIs and oversized login fail closed',
    () async {
      expect((await request('GET', '/context')).$1, 401);
      expect(
        (await request(
          'POST',
          '/auth/login',
          body: {
            'username': SyntheticCoreAccount.username,
            'password': 'incorrect',
            'deviceName': 'Synthetic tablet',
          },
        )).$1,
        401,
      );
      expect(
        (await request(
          'POST',
          '/admin/media/preparations',
          token: SyntheticCoreAccount.accessToken,
          body: {},
        )).$1,
        403,
      );
      expect(
        (await request(
          'GET',
          '/vault',
          token: SyntheticCoreAccount.accessToken,
        )).$1,
        403,
      );
      expect(
        (await request(
          'POST',
          '/auth/login',
          body: {'username': 'x' * 5000},
        )).$1,
        413,
      );
      expect(core.rejectedRequests, 5);
      expect(core.logins, 0);
      expect(host.acceptedActions, isEmpty);
    },
  );
}
