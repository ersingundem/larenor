import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/home_resource_grants_contract_fixture.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_resource_grants.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

class _Actor extends SyntheticCoreAccount {
  _Actor(SyntheticCoreResourceGrants grants) : super(grants: grants);
  String actorRole = 'admin', actorId = '9' * 32;
  bool passwordRequired = false;
  @override
  String get userId => actorId;
  @override
  Map<String, Object?> get user => {
    ...super.user,
    'role': actorRole,
    'mustChangePassword': passwordRequired,
  };
}

void main() {
  late SyntheticHaServer host;
  late _Actor core;
  late SyntheticCoreResourceGrants grants;
  late HttpClient client;
  final contract =
      jsonDecode(homeResourceGrantsContractFixture) as Map<String, dynamic>;
  String getPath() => contract['empty']['path'] as String;
  String putPath() => contract['readOnly']['path'] as String;
  Future<(int, Object?)> request(
    String method,
    String path, {
    Object? body,
    String? raw,
    String? token,
    bool authorized = true,
    bool jsonType = true,
    List<String>? headers,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('${host.baseUrl}/api/v1$path'),
    );
    if (authorized) {
      req.headers.set(
        'authorization',
        'Bearer ${token ?? core.currentAccessToken}',
      );
    }
    if (headers != null) req.headers.set('authorization', headers);
    if (body != null || raw != null) {
      if (jsonType) req.headers.contentType = ContentType.json;
      req.write(raw ?? jsonEncode(body));
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  Future<void> login() async {
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
  }

  setUp(() async {
    host = await SyntheticHaServer.start();
    grants = SyntheticCoreResourceGrants();
    core = _Actor(grants);
    host.coreAccount = core;
    client = FixtureNetwork(host.port).createHttpClient(null);
    await login();
  });
  tearDown(() async {
    grants.close();
    client.close(force: true);
    await host.close();
  });
  for (final path in ['/admin/users', 'grants']) {
    test(
      'missing, duplicate, wrong and old session denied for $path',
      () async {
        final target = path == 'grants' ? getPath() : path;
        expect((await request('GET', target, authorized: false)).$1, 401);
        expect((await request('GET', target, token: 'old-session')).$1, 401);
        expect(
          (await request(
            'GET',
            target,
            headers: ['Bearer ${core.currentAccessToken}', 'Bearer other'],
          )).$1,
          401,
        );
        final old = core.currentAccessToken;
        expect((await request('POST', '/auth/logout')).$1, 204);
        expect((await request('GET', target, token: old)).$1, 401);
        await login();
        expect(core.currentAccessToken, isNot(old));
        expect((await request('GET', target, token: old)).$1, 401);
        expect((await request('GET', target)).$1, 200);
        expect(grants.mutations, isEmpty);
      },
    );
  }
  test(
    'member grant read matches contract and revoke restores hidden404',
    () async {
      await request('PUT', putPath(), body: contract['readOnly']['body']);
      core.actorRole = 'member';
      core.actorId = '3' * 32;
      final member = contract['memberCanRead'];
      final memberReply = await request(member['method'], member['path']);
      expect(memberReply.$1, member['status']);
      expect(memberReply.$2, member['response']);
      expect((await request('GET', getPath())).$1, 403);
      expect((await request('GET', '/admin/users')).$1, 403);
      expect(
        (await request(
          'PUT',
          putPath(),
          body: {
            'expectedAclRevision': 2,
            'permissions': {'read': true, 'write': true},
          },
        )).$1,
        403,
      );
      core.actorRole = 'admin';
      core.actorId = '9' * 32;
      await request(
        'PUT',
        putPath(),
        body: {
          'expectedAclRevision': 2,
          'permissions': {'read': false, 'write': false},
        },
      );
      core.actorRole = 'member';
      core.actorId = '3' * 32;
      final revoked = contract['memberReadRevoked'];
      final revokedReply = await request(revoked['method'], revoked['path']);
      expect(revokedReply.$1, revoked['status']);
      expect(revokedReply.$2, revoked['response']);
      expect(grants.putRequests, 2);
    },
  );
  for (final change in ['core', 'home', 'role', 'password']) {
    test('$change denies current grant requests without mutation', () async {
      if (change == 'core') core.coreId = 'c' * 32;
      if (change == 'home') core.homeId = 'd' * 32;
      if (change == 'role') core.actorRole = 'member';
      if (change == 'password') core.passwordRequired = true;
      final status = change == 'core' || change == 'home' ? 404 : 403;
      expect((await request('GET', getPath())).$1, status);
      expect(
        (await request(
          'PUT',
          putPath(),
          body: contract['readOnly']['body'],
        )).$1,
        status,
      );
      expect(grants.putRequests, 0);
    });
  }
  for (final raw in [
    '{"expectedAclRevision":1,"expectedAclRevision":1,"permissions":{"read":true,"write":false}}',
    '{"expectedAclRevision":1,"permissions":{"read":false,"read":true,"write":false}}',
    r'{"expectedAclRevision":1,"permissions":{"read":false,"\u0072ead":true,"write":false}}',
    '{"expectedAclRevision":true,"permissions":{"read":true,"write":false}}',
    '{"expectedAclRevision":1.0,"permissions":{"read":true,"write":false}}',
    '{"expectedAclRevision":1,"permissions":{"read":false,"write":true}}',
    '{"expectedAclRevision":1,"permissions":{"read":1,"write":false}}',
    '{"expectedAclRevision":1,"permissions":{"read":true,"write":false,"token":"synthetic"}}',
    '{"expectedAclRevision":1,"permissions":{"read":true,"write":false},"owner":"synthetic"}',
    '{"expectedAclRevision":0,"permissions":{"read":true,"write":false}}',
    '[]',
    'null',
    '{"expectedAclRevision":1,"permissions":null}',
  ]) {
    test(
      'noncanonical bounded PUT ${raw.hashCode} is rejected without effect',
      () async {
        expect((await request('PUT', putPath(), raw: raw)).$1, 400);
        expect(grants.mutations, isEmpty);
        expect(grants.aclRevision, 1);
      },
    );
  }
  test(
    'unknown subject, method, query, content type and oversize stay closed',
    () async {
      expect(
        (await request(
          'PUT',
          '${getPath()}/${'4' * 32}',
          body: contract['readOnly']['body'],
        )).$1,
        404,
      );
      expect((await request('DELETE', putPath())).$1, 403);
      expect(
        (await request(
          'PUT',
          '${putPath()}?force=true',
          body: contract['readOnly']['body'],
        )).$1,
        400,
      );
      expect(
        (await request(
          'PUT',
          putPath(),
          body: contract['readOnly']['body'],
          jsonType: false,
        )).$1,
        400,
      );
      expect((await request('PUT', putPath(), raw: ' ' * 4097)).$1, 413);
      expect(grants.mutations, isEmpty);
    },
  );
  test(
    'lost success reply retains one effect and explicit GET never retries PUT',
    () async {
      grants.failNextPutReply = true;
      expect(
        (await request(
          'PUT',
          putPath(),
          body: contract['readOnly']['body'],
        )).$1,
        503,
      );
      expect(grants.putRequests, 1);
      expect(grants.aclRevision, 2);
      final after = contract['afterReadOnly'];
      final reply = await request('GET', getPath());
      expect(reply.$1, after['status']);
      expect(reply.$2, after['response']);
      expect(grants.putRequests, 1);
    },
  );
  test('late revoked session reply is401 while committed grant remains for a fresh login', () async {
    final gate = Completer<void>();
    grants.replyGate = gate;
    final pending = request(
      'PUT',
      putPath(),
      body: contract['readOnly']['body'],
    );
    for (var i = 0; i < 100 && grants.putRequests == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(grants.putRequests, 1);
    core.revokeGrantSession();
    gate.complete();
    expect((await pending).$1, 401);
    await login();
    expect(
      (await request('GET', getPath())).$2,
      contract['afterReadOnly']['response'],
    );
    expect(grants.putRequests, 1);
  });
}
