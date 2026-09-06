import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_people/domain/home_person_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../../integration_test/support/home_people_contract_fixture.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_people_admin_account.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  late SyntheticHaServer host;
  late SyntheticCorePeopleAdminAccount core;
  late HttpClient client;
  final fixture = jsonDecode(homePeopleContractFixture) as Map<String, dynamic>;
  setUp(() async {
    host = await SyntheticHaServer.start();
    core = SyntheticCorePeopleAdminAccount();
    host.coreAccount = core;
    client = FixtureNetwork(host.port).createHttpClient(null);
  });
  tearDown(() async {
    if (core.replyGate?.isCompleted == false) core.replyGate!.complete();
    expect(host.requests, 0);
    expect(host.acceptedActions, isEmpty);
    client.close(force: true);
    await host.close();
  });
  Future<(int, Map<String, dynamic>?)> send(
    String path, {
    String method = 'GET',
    Object? body,
    String? raw,
    String? token,
    bool noToken = false,
    String contentType = 'application/json',
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('${host.baseUrl}/api/v1$path'),
    );
    if (!noToken) {
      request.headers.set(
        'authorization',
        'Bearer ${token ?? core.currentAccessToken}',
      );
    }
    if (body != null || raw != null) {
      request.headers.set('content-type', contentType);
      final bytes = utf8.encode(raw ?? jsonEncode(body));
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (
      response.statusCode,
      text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  Future<void> login() async {
    final r = await send(
      '/auth/login',
      method: 'POST',
      body: {
        'username': SyntheticCoreAccount.username,
        'password': SyntheticCoreAccount.password,
        'deviceName': 'Synthetic tablet',
      },
    );
    expect(r.$1, 200);
    expect(r.$2!['user']['role'], 'admin');
  }

  String base() => '/home-people/${core.coreId}/${core.homeId}';
  String admin() => '/admin${base()}';
  String record() => '${admin()}/${'1' * 32}';
  String acl() => '${record()}/grants';
  Future<void> create() async {
    expect(
      (await send(
        admin(),
        method: 'POST',
        body: fixture['createPerson']['body'],
      )).$1,
      201,
    );
  }

  Future<void> step(String name) async {
    final v = fixture[name] as Map<String, dynamic>;
    final path = Uri(
      path: v['path'] as String,
      queryParameters: (v['query'] as Map).isEmpty
          ? null
          : Map<String, String>.from(v['query'] as Map),
    ).toString();
    final r = await send(path, method: v['method'] as String, body: v['body']);
    expect(r.$1, v['status'], reason: name);
    expect(r.$2, v['response'], reason: name);
  }

  test(
    'fixture creates, updates and grants with actual Server response parity',
    () async {
      await login();
      for (final name in [
        'emptyList',
        'createPerson',
        'createUnicode',
        'emptyGrants',
        'grantRead',
        'grantUnicode',
        'grantsAfterRead',
        'beforeUpdate',
        'adminList',
        'updatePerson',
        'noopPerson',
        'grantWrite',
        'grantNoop',
        'revoke',
        'beforeDelete',
        'deletePerson',
      ]) {
        await step(name);
      }
      expect(core.mutations, [
        'POST',
        'POST',
        'PUT',
        'PUT',
        'PATCH',
        'PATCH',
        'PUT',
        'PUT',
        'PUT',
        'DELETE',
      ]);
      expect(core.records.single['ref']['id'], '2' * 32);
      expect(core.rejectedRequests, 0);
    },
  );
  test('admin users are real typed closed fixtures and basic list/get does not alter data', () async {
    await login();
    await create();
    final users = await send('/admin/users');
    expect(users.$1, 200);
    expect(users.$2!['users'], isA<List>());
    expect((users.$2!['users'] as List).single['id'], fixture['subjectId']);
    final list = await send(base());
    final page = HomePeoplePage.fromJson(
      list.$2,
      expectedContext: ServerContext.fromJson(fixture['context']),
    );
    expect(page.entries.single.label, 'Deniz Öztürk');
    expect(page.entries.single.canWrite, isTrue);
    expect(
      (await send('${base()}/${'1' * 32}')).$2,
      fixture['createPerson']['response'],
    );
    expect(core.usersReads, 1);
    expect(core.peopleReads, 2);
    expect(core.mutations, ['POST']);
  });
  test('current bearer requires login and rotates; retired token cannot read Core auth or people', () async {
    expect((await send(base())).$1, 401);
    await login();
    final old = core.currentAccessToken;
    await login();
    expect(core.currentAccessToken, isNot(old));
    for (final path in [
      base(),
      '/admin/users',
      '/auth/me',
      '/context',
      '/home-resources/${core.coreId}/${core.homeId}',
    ]) {
      expect((await send(path, token: old)).$1, 401);
    }
    core.retireSession();
    expect((await send(base())).$1, 401);
    expect((await send('/auth/me')).$1, 401);
    expect(core.records, isEmpty);
  });
  test(
    'role and foreign scope are closed even with otherwise current bearer',
    () async {
      await login();
      await create();
      core.role = 'member';
      expect((await send(base())).$1, 403);
      expect((await send('/admin/users')).$1, 403);
      core.role = 'admin';
      final path = base();
      core.homeId = 'c' * 32;
      expect((await send(path)).$1, 404);
      expect((await send(base())).$1, 404);
      expect(core.mutations, ['POST']);
    },
  );
  test('metadata and ACL CAS are independent; replay cannot silently repeat effects', () async {
    await login();
    await create();
    await step('grantRead');
    final before = core.records.single;
    expect(before['revision'], 1);
    expect(before['aclRevision'], 2);
    expect(
      (await send(
        record(),
        method: 'PATCH',
        body: {
          'label': 'Changed',
          'order': 0,
          'expectedRevision': 1,
          'expectedAclRevision': 1,
        },
      )).$1,
      409,
    );
    await step('updatePerson');
    expect(
      (await send(
        '${acl()}/${fixture['subjectId']}',
        method: 'PUT',
        body: fixture['grantRead']['body'],
      )).$1,
      409,
    );
    expect(core.records.single['revision'], 2);
    expect(core.records.single['aclRevision'], 2);
    expect(core.mutations, ['POST', 'PUT', 'PATCH']);
  });
  for (final body in [
    <String, Object?>{},
    {'label': '', 'order': 0},
    {'label': 'x', 'order': true},
    {'label': 'x', 'order': 10001},
    {'label': 'x', 'order': 0, 'userId': 'private'},
    {'label': 'x' * 81, 'order': 0},
    {'label': '\u0000', 'order': 0},
  ]) {
    test(
      'malformed metadata shape stays mutation-free ${body.keys.join(',')} ${body.hashCode}',
      () async {
        await login();
        expect((await send(admin(), method: 'POST', body: body)).$1, 400);
        expect(core.records, isEmpty);
        expect(core.mutations, isEmpty);
      },
    );
  }
  for (final raw in [
    '{"label":"a","label":"b","order":0}',
    '{"label":"a","ord\\u0065r":0,"order":1}',
    '[]',
    '{',
    'x' * 4097,
  ]) {
    test(
      'bounded and duplicate JSON rejected ${raw.length} ${raw.hashCode}',
      () async {
        await login();
        expect(
          (await send(admin(), method: 'POST', raw: raw)).$1,
          raw.length > 4096 ? 413 : 400,
        );
        expect(core.mutations, isEmpty);
      },
    );
  }
  test(
    'closed verb/path/query/read-body gates reject without writes',
    () async {
      await login();
      for (final method in ['PUT', 'DELETE', 'PATCH']) {
        expect(
          (await send(
            admin(),
            method: method,
            body: method == 'DELETE' ? null : {'label': 'x', 'order': 0},
          )).$1,
          404,
        );
      }
      expect((await send(base(), method: 'POST', body: {})).$1, 403);
      expect((await send('${base()}/unknown')).$1, 404);
      expect((await send(base(), raw: '{}')).$1, 400);
      for (final query in [
        'limit=0',
        'limit=101',
        'limit=1&limit=2',
        'token=private',
        'after=${'1' * 32}',
        'limit=1%0A',
      ]) {
        expect((await send('${base()}?$query')).$1, 400);
      }
      expect(
        (await send(
          '${admin()}?extra=1',
          method: 'POST',
          body: {'label': 'x', 'order': 0},
        )).$1,
        400,
      );
      expect(core.mutations, isEmpty);
    },
  );
  test('body wait rechecks token before effect', () async {
    await login();
    core.bodyStarted = Completer<void>();
    final call = await client.postUrl(
      Uri.parse('${host.baseUrl}/api/v1${admin()}'),
    );
    call.headers.set('authorization', 'Bearer ${core.currentAccessToken}');
    call.headers.contentType = ContentType.json;
    call.bufferOutput = false;
    call.write('{');
    await call.flush();
    await core.bodyStarted!.future.timeout(const Duration(seconds: 3));
    core.retireSession();
    call.write('"label":"late","order":0}');
    final reply = await call.close();
    await reply.drain<void>();
    expect(reply.statusCode, 401);
    expect(core.mutations, isEmpty);
  });
  test('late ACK rechecks scope after one effect and never replays', () async {
    await login();
    final gate = core.replyGate = Completer<void>();
    final pending = send(
      admin(),
      method: 'POST',
      body: fixture['createPerson']['body'],
    );
    for (var i = 0; core.mutations.isEmpty && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(core.mutations, ['POST']);
    core.homeId = 'c' * 32;
    gate.complete();
    final reply = await pending;
    expect(reply.$1, 404);
    expect(core.records.length, 1);
    expect(core.mutations, ['POST']);
    expect(core.rejectedRequests, 1);
  });

  Future<void> changeAuthority(String mode) async {
    switch (mode) {
      case 'login':
        await login();
      case 'retire':
        core.retireSession();
      case 'role':
        core.role = 'member';
      case 'core':
        core.coreId = 'c' * 32;
      case 'home':
        core.homeId = 'c' * 32;
    }
  }

  int deniedStatus(String mode) => switch (mode) {
    'login' || 'retire' => 401,
    'role' => 403,
    _ => 404,
  };
  for (final mode in ['login', 'role', 'core', 'home']) {
    test('streaming body authority $mode changes before effect', () async {
      await login();
      core.bodyStarted = Completer<void>();
      final call = await client.postUrl(
        Uri.parse('${host.baseUrl}/api/v1${admin()}'),
      );
      call.headers.set('authorization', 'Bearer ${core.currentAccessToken}');
      call.headers.contentType = ContentType.json;
      call.bufferOutput = false;
      call.write('{');
      await call.flush();
      await core.bodyStarted!.future.timeout(const Duration(seconds: 3));
      await changeAuthority(mode);
      call.write('"label":"late","order":0}');
      final response = await call.close();
      await response.drain<void>();
      expect(response.statusCode, deniedStatus(mode));
      expect(core.records, isEmpty);
      expect(core.mutations, isEmpty);
      expect(core.rejectedRequests, 1);
    });
  }
  for (final mode in ['login', 'retire', 'role', 'core']) {
    test(
      'delayed ACK authority $mode changes after exactly one effect',
      () async {
        await login();
        final gate = core.replyGate = Completer<void>();
        final pending = send(
          admin(),
          method: 'POST',
          body: fixture['createPerson']['body'],
        );
        for (var i = 0; core.mutations.isEmpty && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(core.mutations, ['POST']);
        await changeAuthority(mode);
        gate.complete();
        expect((await pending).$1, deniedStatus(mode));
        expect(core.records, hasLength(1));
        expect(core.mutations, ['POST']);
        expect(core.rejectedRequests, 1);
      },
    );
  }
  test(
    'closed grants, delete, content-type and duplicate authorization gates',
    () async {
      await login();
      expect(
        (await send(
          admin(),
          method: 'POST',
          body: fixture['createPerson']['body'],
          contentType: 'text/plain',
        )).$1,
        400,
      );
      expect((await send(base(), noToken: true)).$1, 401);
      final call = await client.getUrl(
        Uri.parse('${host.baseUrl}/api/v1${base()}'),
      );
      call.headers.add('authorization', 'Bearer ${core.currentAccessToken}');
      call.headers.add('authorization', 'Bearer ${core.currentAccessToken}');
      final duplicate = await call.close();
      await duplicate.drain<void>();
      expect(duplicate.statusCode, 401);
      await create();
      for (final body in [
        {
          'expectedAclRevision': true,
          'permissions': {'read': true, 'write': false},
        },
        {
          'expectedAclRevision': 1,
          'permissions': {'read': false, 'write': true},
        },
        {
          'expectedAclRevision': 1,
          'permissions': {'read': true, 'write': false, 'admin': true},
        },
        {
          'expectedAclRevision': 1,
          'permissions': {'read': 'true', 'write': false},
        },
      ]) {
        expect(
          (await send(
            '${acl()}/${core.subjectId}',
            method: 'PUT',
            body: body,
          )).$1,
          400,
        );
      }
      expect(
        (await send(
          '${acl()}/${'a' * 32}',
          method: 'PUT',
          body: fixture['grantRead']['body'],
        )).$1,
        404,
      );
      expect((await send('${base()}/${core.firstId}%0A')).$1, 404);
      expect(
        (await send(
          '${record()}?expectedRevision=1&expectedAclRevision=1&extra=1',
          method: 'DELETE',
        )).$1,
        400,
      );
      expect(
        (await send(
          '${record()}?expectedRevision=1&expectedAclRevision=2',
          method: 'DELETE',
        )).$1,
        409,
      );
      expect(core.records.single['revision'], 1);
      expect(core.records.single['aclRevision'], 1);
      expect(core.mutations, ['POST']);
    },
  );
  test('snapshot pagination is consistent and returned records cannot mutate fixture', () async {
    await login();
    await create();
    await step('createUnicode');
    final page = await send('${base()}?limit=1');
    expect(page.$1, 200);
    expect(page.$2!['entries'], hasLength(1));
    expect(page.$2!['nextAfter'], core.firstId);
    final snapshot = page.$2!['snapshot'];
    final next = await send(
      '${base()}?limit=1&after=${core.firstId}&expectedSnapshot=$snapshot',
    );
    expect(next.$1, 200);
    expect(next.$2!['entries'].single['ref']['id'], '2' * 32);
    expect(next.$2!['nextAfter'], isNull);
    final copy = core.records;
    copy.first['ref']['id'] = '9' * 32;
    copy.first['label'] = 'Tampered';
    expect(core.records.first['ref']['id'], core.firstId);
    expect(core.records.first['label'], 'Deniz Öztürk');
    expect(() => copy.add({}), throwsUnsupportedError);
    expect(() => core.mutations.add('PUT'), throwsUnsupportedError);
    await step('grantRead');
    expect(
      (await send('${base()}?after=${core.firstId}&expectedSnapshot=$snapshot'))
          .$1,
      409,
    );
    expect(core.mutations, ['POST', 'POST', 'PUT']);
  });
  test(
    'ordinary delayed-ACK timeout remains a rejected request with one effect',
    () async {
      await login();
      final gate = core.replyGate = Completer<void>();
      final response = await send(
        admin(),
        method: 'POST',
        body: fixture['createPerson']['body'],
      );
      gate.complete();
      expect(response.$1, 503);
      expect(response.$2, {
        'error': {'code': 'service_unavailable'},
      });
      expect(core.rejectedRequests, 1);
      expect(core.injectedAckLosses, 0);
      expect(core.mutations, ['POST']);
    },
  );
  test(
    'closed client before ACK never replays metadata or escapes server cleanup',
    () async {
      await login();
      final gate = core.replyGate = Completer<void>();
      final pending = send(
        admin(),
        method: 'POST',
        body: fixture['createPerson']['body'],
      );
      final failed = expectLater(
        pending,
        throwsA(anyOf(isA<HttpException>(), isA<SocketException>())),
      );
      for (var i = 0; core.mutations.isEmpty && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(core.mutations, ['POST']);
      client.close(force: true);
      await failed;
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(core.records, hasLength(1));
      expect(core.mutations, ['POST']);
      expect(core.rejectedRequests, 0);
      expect(core.injectedAckLosses, 0);
    },
  );
}
