import 'dart:async';
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
  final contract =
      jsonDecode(homeResourceAdminContractFixture) as Map<String, dynamic>;
  final create = contract['createRoom'] as Map<String, dynamic>;

  setUp(() async {
    host = await SyntheticHaServer.start();
    admin = SyntheticCoreResourceAdmin();
    core = SyntheticCoreAccount(adminResources: admin);
    host.coreAccount = core;
    client = FixtureNetwork(host.port).createHttpClient(null);
  });
  tearDown(() async {
    admin.close();
    client.close(force: true);
    await host.close();
  });

  Future<(int, Object?)> request(
    String method,
    String path, {
    Object? body,
    String? raw,
    bool authorized = true,
    List<int>? bytes,
    List<String>? authorization,
    bool jsonType = true,
  }) async {
    final outgoing = await client.openUrl(
      method,
      Uri.parse('${host.baseUrl}/api/v1$path'),
    );
    if (authorized) {
      outgoing.headers.set(
        'authorization',
        'Bearer ${SyntheticCoreAccount.accessToken}',
      );
    }
    if (authorization != null) {
      outgoing.headers.set('authorization', authorization);
    }
    if (body != null || raw != null || bytes != null) {
      if (jsonType) outgoing.headers.contentType = ContentType.json;
      final payload = bytes ?? utf8.encode(raw ?? jsonEncode(body));
      outgoing.contentLength = payload.length;
      outgoing.add(payload);
    }
    final incoming = await outgoing.close();
    final text = await utf8.decodeStream(incoming);
    return (incoming.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  String listPath() => '/home-resources/${core.coreId}/${core.homeId}';

  test('bundled admin contract equals actual Server HTTP fixture', () {
    expect(
      contract,
      jsonDecode(
        File('contracts/home-resource-admin.v1.json').readAsStringSync(),
      ),
    );
  });
  test(
    'explicit admin creates exact contract record and fresh authenticated list',
    () async {
      expect((await request('GET', listPath())).$1, 200);
      expect(
        (await request(
          'POST',
          create['path'] as String,
          body: create['body'],
        )).$1,
        201,
      );
      expect(admin.records.single, create['response']['record']);
      final (_, page) = await request('GET', listPath());
      expect((page as Map)['entries'], [create['response']['record']]);
      expect(admin.mutations, ['POST']);
      expect(admin.reads, 2);
      expect(host.requests, 0);
      expect(host.acceptedActions, isEmpty);
    },
  );
  test('rename and order then exact delete are metadata only', () async {
    await request('POST', create['path'] as String, body: create['body']);
    final path = '${create['path']}/${'1' * 32}';
    final (status, result) = await request(
      'PATCH',
      path,
      body: {
        'label': 'Renamed room',
        'order': 7,
        'expectedRevision': 1,
        'expectedAclRevision': 1,
      },
    );
    expect(status, 200);
    expect((result as Map)['record']['revision'], 2);
    expect(admin.records.single['order'], 7);
    expect(
      (await request(
        'DELETE',
        '$path?expectedRevision=2&expectedAclRevision=1',
      )).$1,
      204,
    );
    expect((await request('GET', '${listPath()}/${'1' * 32}')).$1, 404);
    expect(admin.records, isEmpty);
    expect(admin.mutations, ['POST', 'PATCH', 'DELETE']);
    expect(host.requests, 0);
  });
  test(
    'unknown duplicate and stale write inputs never change records',
    () async {
      await request('POST', create['path'] as String, body: create['body']);
      final before = jsonEncode(admin.records);
      for (final raw in [
        '{"kind":"room","label":"A","label":"B","order":0}',
        '{"kind":"room","label":"A","order":0,"token":"private"}',
      ]) {
        expect(
          (await request('POST', create['path'] as String, raw: raw)).$1,
          400,
        );
      }
      final path = '${create['path']}/${'1' * 32}';
      expect(
        (await request(
          'PATCH',
          path,
          body: {
            'label': 'Stale',
            'order': 0,
            'expectedRevision': 2,
            'expectedAclRevision': 1,
          },
        )).$1,
        409,
      );
      expect(
        (await request(
          'DELETE',
          '$path?expectedRevision=1&expectedRevision=1&expectedAclRevision=1',
        )).$1,
        400,
      );
      expect(jsonEncode(admin.records), before);
      expect(admin.mutations, ['POST']);
      expect(host.requests, 0);
    },
  );
  test(
    'wrong auth scope and member role deny all metadata mutations',
    () async {
      expect(
        (await request(
          'POST',
          create['path'] as String,
          body: create['body'],
          authorized: false,
        )).$1,
        401,
      );
      expect(
        (await request(
          'POST',
          '/admin/home-resources/${'c' * 32}/${'d' * 32}',
          body: create['body'],
        )).$1,
        404,
      );
      host.coreAccount = _Member(admin);
      expect(
        (await request(
          'POST',
          create['path'] as String,
          body: create['body'],
        )).$1,
        403,
      );
      expect(admin.records, isEmpty);
      expect(admin.mutations, isEmpty);
      expect(host.requests, 0);
    },
  );
  test(
    'default and existing member fixtures never opt into admin writes',
    () async {
      for (final actor in [
        SyntheticCoreAccount(),
        SyntheticCoreAccount(resources: SyntheticCoreResources()),
      ]) {
        host.coreAccount = actor;
        expect(
          (await request(
            'POST',
            create['path'] as String,
            body: create['body'],
          )).$1,
          403,
        );
      }
      expect(admin.mutations, isEmpty);
      expect(host.requests, 0);
      expect(
        () => SyntheticCoreAccount(
          resources: SyntheticCoreResources(),
          adminResources: admin,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'all successful shared contract operations cross real loopback',
    () async {
      for (final name in ['createRoom', 'createResource']) {
        final item = contract[name] as Map<String, dynamic>;
        final result = await request(
          item['method'] as String,
          item['path'] as String,
          body: item['body'],
        );
        expect(result.$1, item['status'], reason: name);
        expect(result.$2, item['response'], reason: name);
      }
      admin = SyntheticCoreResourceAdmin.beforeUpdate();
      host.coreAccount = SyntheticCoreAccount(adminResources: admin);
      for (final name in [
        'updateRoom',
        'noopRoom',
        'staleUpdate',
        'deleteRoom',
        'deletedRead',
      ]) {
        final item = contract[name] as Map<String, dynamic>;
        final query = item['query'] as Map<String, dynamic>?;
        final path = Uri(
          path: item['path'] as String,
          queryParameters: query?.cast<String, String>(),
        ).toString();
        final result = await request(
          item['method'] as String,
          path,
          body: item['body'],
        );
        expect(result.$1, item['status'], reason: name);
        if (result.$1 < 300) {
          expect(result.$2, item['response'], reason: name);
        } else {
          expect(
            (result.$2 as Map)['error']['code'],
            item['response']['error']['code'],
          );
        }
      }
      expect(admin.records, isEmpty);
      expect(admin.mutations, ['PATCH', 'PATCH', 'DELETE']);
      expect(host.requests, 0);
    },
  );
  for (final invalid in <String>[
    '{',
    '[]',
    'null',
    r'{"kind":"room","label":"A","l\u0061bel":"B","order":0}',
    '{"kind":"room","label":"A","order":0,"acl":{"write":true}}',
    '{"kind":"room","label":["A"],"order":0}',
    '{"kind":"room","label":"A","order":true}',
    '{"kind":"room","label":"A","order":1.0}',
    '{"kind":"room","label":"A","order":-1}',
    '{"kind":"room","label":"A","order":10001}',
    '{"kind":"device_action","label":"A","order":0}',
    '{"kind":"room","label":"   ","order":0}',
    r'{"kind":"room","label":"bad\u0000private","order":0}',
    r'{"kind":"room","label":"bad\ud800","order":0}',
    jsonEncode({'kind': 'room', 'label': '🌿' * 81, 'order': 0}),
  ]) {
    test(
      'invalid flat mutation rejects without echo or effect: ${invalid.hashCode}',
      () async {
        final reply = await request(
          'POST',
          create['path'] as String,
          raw: invalid,
        );
        expect(reply.$1, 400);
        expect(reply.$2, {
          'error': {'code': 'invalid_request'},
        });
        expect(admin.records, isEmpty);
        expect(admin.mutations, isEmpty);
        expect(host.requests, 0);
      },
    );
  }
  test('JSON escapes whitespace and Unicode label remain supported', () async {
    final reply = await request(
      'POST',
      create['path'] as String,
      raw: r' { "kind" : "room", "label" : "  A \\ B \" C : D 🌿  ", "order" : 3 } ',
    );
    expect(reply.$1, 201);
    expect(admin.records.single['label'], r'A \ B " C : D 🌿');
  });
  test(
    'invalid UTF8 absent content type and oversized body are bounded',
    () async {
      expect(
        (await request('POST', create['path'] as String, bytes: [0xff])).$1,
        400,
      );
      expect(
        (await request(
          'POST',
          create['path'] as String,
          body: create['body'],
          jsonType: false,
        )).$1,
        400,
      );
      expect(
        (await request('POST', create['path'] as String, raw: ' ' * 4097)).$1,
        413,
      );
      expect(admin.mutations, isEmpty);
      expect(admin.records, isEmpty);
    },
  );
  test(
    'closed methods body and query vocabulary prevent extra effects',
    () async {
      await request('POST', create['path'] as String, body: create['body']);
      final path = '${create['path']}/${'1' * 32}';
      for (final target in [
        ('PUT', path),
        ('GET', create['path'] as String),
        ('POST', listPath()),
        ('POST', path),
        ('PATCH', create['path'] as String),
      ]) {
        expect(
          (await request(target.$1, target.$2, body: create['body'])).$1,
          isIn([403, 404]),
        );
      }
      for (final query in [
        '?extra=1',
        '?expectedRevision=1',
        '?expectedRevision=01&expectedAclRevision=1',
        '?expectedRevision=9223372036854775808&expectedAclRevision=1',
        '?expectedRevision=1&expectedAclRevision=1&extra=1',
      ]) {
        expect((await request('DELETE', '$path$query')).$1, 400);
      }
      expect(
        (await request(
          'DELETE',
          '$path?expectedRevision=1&expectedAclRevision=1',
          body: {},
        )).$1,
        400,
      );
      expect(
        (await request(
          'POST',
          '${create['path']}?extra=1',
          body: create['body'],
        )).$1,
        400,
      );
      expect((await request('GET', listPath(), body: {})).$1, 400);
      expect(
        (await request('GET', '${listPath()}/${'1' * 32}?extra=1')).$1,
        400,
      );
      expect(
        (await request(
          'PATCH',
          path,
          body: {
            'label': 'A',
            'order': 0,
            'expectedRevision': true,
            'expectedAclRevision': 1,
          },
        )).$1,
        400,
      );
      expect(
        (await request(
          'DELETE',
          '$path?expectedRevision=1&expectedAclRevision=2',
        )).$1,
        409,
      );
      expect(admin.mutations, ['POST']);
      expect(admin.records.single, create['response']['record']);
    },
  );
  test(
    'duplicate authorization and wrong current fixture scope reject',
    () async {
      expect(
        (await request(
          'POST',
          create['path'] as String,
          body: create['body'],
          authorization: [
            'Bearer ${SyntheticCoreAccount.accessToken}',
            'Bearer other',
          ],
        )).$1,
        401,
      );
      core.homeId = 'd' * 32;
      expect(
        (await request(
          'POST',
          create['path'] as String,
          body: create['body'],
        )).$1,
        404,
      );
      expect(admin.records, isEmpty);
      expect(admin.mutations, isEmpty);
    },
  );
  test(
    'snapshot paging is scoped fresh and invalidated by metadata mutations',
    () async {
      for (var index = 0; index < 3; index++) {
        await request(
          'POST',
          create['path'] as String,
          body: {'kind': 'room', 'label': 'Room $index', 'order': index},
        );
      }
      final first = (await request('GET', '${listPath()}?limit=1')).$2 as Map;
      expect((first['entries'] as List).length, 1);
      expect(first['nextAfter'], isNotNull);
      final after = first['nextAfter'], snapshot = first['snapshot'];
      final second =
          (await request(
                'GET',
                '${listPath()}?limit=1&after=$after&expectedSnapshot=$snapshot',
              )).$2
              as Map;
      expect(second['snapshot'], snapshot);
      expect(second['entries'][0]['ref']['id'], isNot(after));
      for (final query in [
        '?limit=0',
        '?limit=101',
        '?limit=01',
        '?limit=1&limit=1',
        '?extra=1',
        '?after=$after',
        '?expectedSnapshot=x',
      ]) {
        expect((await request('GET', '${listPath()}$query')).$1, 400);
      }
      expect(
        (await request(
          'GET',
          '${listPath()}?after=${'f' * 32}&expectedSnapshot=$snapshot',
        )).$1,
        404,
      );
      await request(
        'POST',
        create['path'] as String,
        body: {'kind': 'resource', 'label': 'Changed', 'order': 0},
      );
      expect(
        (await request(
          'GET',
          '${listPath()}?after=$after&expectedSnapshot=$snapshot',
        )).$1,
        409,
      );
      final exposed = admin.records;
      exposed.first['label'] = 'External mutation';
      expect(admin.records.first['label'], isNot('External mutation'));
      expect(host.requests, 0);
      expect(host.acceptedActions, isEmpty);
    },
  );
  test(
    'delayed ACK keeps exactly one effect and requires explicit release',
    () async {
      final gate = Completer<void>();
      admin.replyGate = gate;
      var completed = false;
      final pending =
          request('POST', create['path'] as String, body: create['body']).then((
            reply,
          ) {
            completed = true;
            return reply;
          });
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (admin.mutations.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(admin.mutations, ['POST']);
      expect(admin.records.single, create['response']['record']);
      expect(completed, isFalse);
      gate.complete();
      expect((await pending).$1, 201);
      expect(admin.mutations, ['POST']);
      expect(admin.replyGate, isNull);
    },
  );
  test(
    'lost response timeout never retries or rolls back the in-memory effect',
    () async {
      admin.replyGate = Completer<void>();
      final reply = await request(
        'POST',
        create['path'] as String,
        body: create['body'],
      );
      expect(reply.$1, 503);
      expect(reply.$2, {
        'error': {'code': 'service_unavailable'},
      });
      expect(admin.records.single, create['response']['record']);
      expect(admin.mutations, ['POST']);
      expect(admin.replyGate, isNull);
    },
  );
  test('disposable fixture record cap is bounded without ID reuse', () async {
    for (var index = 0; index < 32; index++) {
      expect(
        (await request(
          'POST',
          create['path'] as String,
          body: {'kind': 'room', 'label': 'R$index', 'order': 0},
        )).$1,
        201,
      );
    }
    expect(admin.records.map((row) => row['ref']['id']).toSet().length, 32);
    expect(
      (await request(
        'POST',
        create['path'] as String,
        body: create['body'],
      )).$1,
      409,
    );
    expect(admin.mutations.length, 32);
    expect(admin.records.length, 32);
  });
}
