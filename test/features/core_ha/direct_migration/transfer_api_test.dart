import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/core_ha/direct_migration/transfer_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../core_ha_api_test.dart' show serviceJson, response;
import '../core_ha_models_test.dart'
    show target, refJson, bindingJson, projectionJson, failure;

Map<String, dynamic> transferPreviewJson() => {
  'id': '6' * 32,
  'requestId': '7' * 32,
  'expiresInMs': 60000,
  'ref': refJson(),
  'resourceRevision': 1,
  'aclRevision': 1,
  'service': serviceJson(),
  'binding': bindingJson(),
  'projection': projectionJson(commandAvailable: false),
};
Map<String, dynamic> transferReceiptJson() => {
  'schemaVersion': 1,
  'requestId': '7' * 32,
  'status': 'committed',
  'ref': refJson(),
  'resourceRevision': 1,
  'aclRevision': 1,
  'service': serviceJson(),
  'binding': bindingJson(),
};

void main() {
  CoreHaTransferApi create(
    Future<http.Response> Function(http.Request) handle, {
    bool Function()? current,
  }) {
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.invalid/root'),
      client: MockClient(handle),
    );
    addTearDown(transport.close);
    return CoreHaTransferApi(
      transport,
      'core_session',
      target(),
      isCurrent: current ?? () => true,
    );
  }

  Future<dynamic> preview(
    CoreHaTransferApi api, {
    String credential = 'local_secret',
  }) => api.preview(
    requestId: '7' * 32,
    name: 'Home service',
    baseUrl: 'http://synthetic.invalid',
    credential: credential,
    entityId: 'switch.reading_lamp',
  );

  test('explicit transfer preview sends the exact bounded POST once', () async {
    final requests = <http.Request>[];
    final api = create((r) async {
      requests.add(r);
      return response({'preview': transferPreviewJson()}, 201);
    });
    final value = await preview(api);
    expect(value.requestId, '7' * 32);
    expect(value.projection.commandAvailable, isFalse);
    expect(requests.single.method, 'POST');
    expect(
      requests.single.url.path,
      '/root/api/v1/admin/home-assistant/${target().context.coreId}/${target().context.homeId}/resources/${target().id}/direct-migration/preview',
    );
    expect(requests.single.headers['authorization'], 'Bearer core_session');
    expect(requests.single.followRedirects, isFalse);
    expect(requests.single.url.query, isEmpty);
    expect(jsonDecode(requests.single.body), {
      'requestId': '7' * 32,
      'name': 'Home service',
      'baseUrl': 'http://synthetic.invalid',
      'token': 'local_secret',
      'entityId': 'switch.reading_lamp',
      'expectedRevision': 1,
      'expectedAclRevision': 1,
    });
    expect('$api $value', isNot(contains('local_secret')));
  });
  for (final credential in [
    '',
    'bad token',
    'bad\n',
    '\u007f',
    'ş',
    'a' * 2049,
  ]) {
    test(
      'invalid transfer token ${credential.length}/${credential.codeUnits.firstOrNull} makes zero requests',
      () async {
        var calls = 0;
        final api = create((_) async {
          calls++;
          return response({'preview': transferPreviewJson()}, 201);
        });
        await expectLater(
          preview(api, credential: credential),
          throwsA(failure('invalid_request')),
        );
        expect(calls, 0);
      },
    );
  }
  test(
    'retired adapter never revives and stale401 becomes cancelled',
    () async {
      var current = true, calls = 0;
      final reply = Completer<http.Response>();
      final api = create((_) {
        calls++;
        return reply.future;
      }, current: () => current);
      final pending = preview(api);
      await Future<void>.delayed(Duration.zero);
      current = false;
      reply.complete(
        response({
          'error': {'code': 'unauthorized'},
        }, 401),
      );
      await expectLater(pending, throwsA(failure('cancelled')));
      current = true;
      await expectLater(preview(api), throwsA(failure('cancelled')));
      expect(calls, 1);
    },
  );
  for (final item in [
    ('ha_migration_changed', 409),
    ('ha_migration_preview_invalid', 409),
    ('ha_migration_limit_reached', 429),
  ]) {
    test(
      'migration ${item.$1} uses only the exact HTTP status mapping',
      () async {
        var status = item.$2;
        final transport = LarenorServerApi(
          endpoint: ServerEndpoint('https://core.invalid'),
          client: MockClient(
            (_) async => response({
              'error': {'code': item.$1},
            }, status),
          ),
        );
        addTearDown(transport.close);
        await expectLater(
          transport.request(
            'POST',
            '/admin/home-assistant/x',
            token: 'core_session',
          ),
          throwsA(failure(item.$1)),
        );
        status = 502;
        await expectLater(
          transport.request(
            'POST',
            '/admin/home-assistant/x',
            token: 'core_session',
          ),
          throwsA(failure('server_error')),
        );
      },
    );
  }
}
