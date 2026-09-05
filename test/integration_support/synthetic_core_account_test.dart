import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    client = HttpClient();
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
    final (status, pair) = await request('POST', '/auth/login', body: {
      'username': SyntheticCoreAccount.username,
      'password': SyntheticCoreAccount.password,
      'deviceName': 'Synthetic tablet',
    });
    expect(status, 200);
    expect(pair['accessToken'], SyntheticCoreAccount.accessToken);
    final (meStatus, me) = await request(
      'GET', '/auth/me', token: pair['accessToken'] as String,
    );
    expect(meStatus, 200);
    expect(me['user'], pair['user']);
    final (contextStatus, context) = await request(
      'GET', '/context', token: pair['accessToken'] as String,
    );
    expect(contextStatus, 200);
    expect(context['coreId'], core.coreId);
    expect(context['homeId'], core.homeId);
    expect(host.reads, isEmpty);
    expect(host.subscriptions, 0);
    expect(core.rejectedRequests, 0);
  });

  test('context is re-read after same-address Core replacement', () async {
    final (_, first) = await request(
      'GET', '/context', token: SyntheticCoreAccount.accessToken,
    );
    core.coreId = 'c' * 32;
    core.homeId = 'd' * 32;
    final (_, second) = await request(
      'GET', '/context', token: SyntheticCoreAccount.accessToken,
    );
    expect(first, isNot(second));
    expect(second['coreId'], core.coreId);
    expect(core.contextReads, 2);
  });

  test('wrong credentials, arbitrary APIs and oversized login fail closed', () async {
    expect((await request('GET', '/context')).$1, 401);
    expect((await request('POST', '/auth/login', body: {
      'username': SyntheticCoreAccount.username,
      'password': 'incorrect',
      'deviceName': 'Synthetic tablet',
    })).$1, 401);
    expect((await request('POST', '/admin/media/preparations',
      token: SyntheticCoreAccount.accessToken, body: {},
    )).$1, 403);
    expect((await request('GET', '/vault',
      token: SyntheticCoreAccount.accessToken,
    )).$1, 403);
    expect((await request('POST', '/auth/login', body: {
      'username': 'x' * 5000,
    })).$1, 413);
    expect(core.rejectedRequests, 5);
    expect(core.logins, 0);
    expect(host.acceptedActions, isEmpty);
  });
}
