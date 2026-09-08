import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/core_ha/data/core_ha_api.dart';
import 'package:larenor/features/core_ha/direct_migration/transfer_api.dart';
import 'package:larenor/features/core_ha/direct_migration/transfer_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../core_ha_api_test.dart' show response;
import '../core_ha_models_test.dart' show failure;

void main() {
  final f = jsonDecode(
    File('contracts/home-assistant-direct-migration.v1.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final target = HomeResourceRecord.fromJson(
    f['resource'],
    expectedContext: ServerContext.fromJson(f['context']),
  );
  final input = f['preview']['body'] as Map<String, dynamic>;
  CoreHaTransferPreview parse(String key) => CoreHaTransferPreview.fromJson(
    f[key]['response']['preview'],
    target: target,
    requestId: input['requestId'] as String,
  );
  test('real Server HTTP contract: 14 adapter requests and one locally rejected changed confirm', () async {
    final requests = <http.Request>[];
    String step = 'notCommitted';
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: MockClient((r) async {
        requests.add(r);
        final expected = f[step] as Map<String, dynamic>;
        expect(r.method, expected['method']);
        expect(r.url.path, '/api/v1${expected['path']}');
        expect(r.url.query, isEmpty);
        expect(r.headers['authorization'], 'Bearer core_fixture');
        if (expected['body'] != null) {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          expect(body.remove('token'), 'synthetic-transfer-token');
          expect(body, expected['body']);
        } else {
          expect(r.body, isEmpty);
        }
        return response(expected['response'], expected['status'] as int);
      }),
    );
    addTearDown(transport.close);
    final api = CoreHaTransferApi(
      transport,
      'core_fixture',
      target,
      isCurrent: () => true,
    );
    Future<CoreHaTransferPreview> prepare() => api.preview(
      requestId: f[step]['body']['requestId'] as String,
      name: input['name'] as String,
      baseUrl: input['baseUrl'] as String,
      credential: 'synthetic-transfer-token',
      entityId: input['entityId'] as String,
    );
    Future<CoreHaTransferReceipt> confirm(
      CoreHaTransferPreview p, {
      String? name,
    }) => api.confirm(
      p,
      name: name ?? input['name'] as String,
      baseUrl: input['baseUrl'] as String,
      credential: 'synthetic-transfer-token',
      entityId: input['entityId'] as String,
    );
    final original = parse('preview');
    expect(await api.result(original), isNull);
    step = 'memberDenied';
    await expectLater(prepare(), throwsA(failure('forbidden')));
    step = 'preview';
    final first = await prepare();
    step = 'cancel';
    await api.cancel(first);
    step = 'cancelledConfirm';
    await expectLater(
      confirm(first),
      throwsA(failure('ha_migration_preview_invalid')),
    );
    step = 'secondPreview';
    final second = await prepare();
    step = 'confirm';
    final receipt = await confirm(second);
    expect(receipt.sameCommit(second.commit), isTrue);
    step = 'result';
    expect((await api.result(second))!.sameCommit(receipt), isTrue);
    step = 'duplicateConfirm';
    expect((await confirm(second)).sameCommit(receipt), isTrue);
    final before = requests.length;
    await expectLater(
      confirm(second, name: 'Different'),
      throwsA(failure('invalid_request')),
    );
    expect(requests.length, before);
    step = 'alreadyBound';
    await expectLater(prepare(), throwsA(failure('ha_migration_changed')));
    step = 'snapshot';
    expect(
      (await CoreHaApi(
        transport,
        'core_fixture',
        target,
        isCurrent: () => true,
      ).snapshot()).projection.state.name,
      'off',
    );
    step = 'memberResultDenied';
    await expectLater(api.result(second), throwsA(failure('forbidden')));
    step = 'restartResult';
    expect((await api.result(second))!.sameCommit(receipt), isTrue);
    step = 'coreUnauthorized';
    await expectLater(api.result(second), throwsA(failure('unauthorized')));
    expect(requests.length, 14);
  });
  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'extra secret': (v) => v['token'] = 'private',
    'foreign home': (v) => (v['ref'] as Map)['homeId'] = '0' * 32,
    'wrong resource revision': (v) => v['resourceRevision'] = 2,
    'wrong ACL revision': (v) => v['aclRevision'] = 2,
    'wrong request': (v) => v['requestId'] = '0' * 32,
    'unknown service key': (v) => (v['service'] as Map)['token'] = 'private',
    'wrong service kind': (v) => (v['service'] as Map)['kind'] = 'jellyfin',
    'old service': (v) => (v['service'] as Map)['revision'] = 2,
    'wrong credentials': (v) =>
        (v['service'] as Map)['credentialKeys'] = ['password'],
    'foreign binding': (v) =>
        ((v['binding'] as Map)['ref'] as Map)['coreId'] = '0' * 32,
    'wrong pair': (v) => (v['binding'] as Map)['serviceId'] = '0' * 32,
    'rebound': (v) => (v['binding'] as Map)['revision'] = 2,
  }.entries) {
    test('public receipt rejects ${mutation.key}', () {
      final raw = jsonDecode(
        jsonEncode(f['confirm']['response']['receipt']),
      ) as Map<String, dynamic>;
      mutation.value(raw);
      expect(
        () => CoreHaTransferReceipt.fromJson(
          raw,
          target: target,
          requestId: input['requestId'] as String,
        ),
        throwsA(failure('invalid_response')),
      );
    });
  }
  for (final ttl in [0, 60001, true, 1.0]) {
    test('preview rejects invalid TTL $ttl', () {
      final raw = jsonDecode(
        jsonEncode(f['preview']['response']['preview']),
      ) as Map<String, dynamic>;
      raw['expiresInMs'] = ttl;
      expect(
        () => CoreHaTransferPreview.fromJson(
          raw,
          target: target,
          requestId: input['requestId'] as String,
        ),
        throwsA(failure('invalid_response')),
      );
    });
  }
  test('migration projection never exposes command authority', () {
    final raw = jsonDecode(
      jsonEncode(f['preview']['response']['preview']),
    ) as Map<String, dynamic>;
    (raw['projection'] as Map)['commandAvailable'] = true;
    expect(
      () => CoreHaTransferPreview.fromJson(
        raw,
        target: target,
        requestId: input['requestId'] as String,
      ),
      throwsA(failure('invalid_response')),
    );
  });
}
