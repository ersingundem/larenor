import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  test('known service errors require the exact matching HTTP status', () async {
    for (final entry in [
      (409, 'service_limit_reached', 'service_limit_reached'),
      (400, 'service_credentials_required', 'service_credentials_required'),
      (400, 'service_limit_reached', 'invalid_request'),
      (409, 'service_credentials_required', 'conflict'),
      (409, 'untrusted service secret', 'conflict'),
    ]) {
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test'),
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': {'code': entry.$2},
            }),
            entry.$1,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.request('GET', '/admin/services'),
        throwsA(
          isA<LarenorServerException>().having((e) => e.code, 'code', entry.$3),
        ),
      );
    }
  });
  test(
    'forget carries only a bounded revision on the exact service route',
    () async {
      final calls = <http.Request>[];
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test/prefix'),
        client: MockClient((request) async {
          calls.add(request);
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      await api.request(
        'DELETE',
        '/admin/services/$id',
        queryParameters: {'expectedRevision': '7'},
        allowEmpty: true,
      );
      expect(calls.single.url.path, '/prefix/api/v1/admin/services/$id');
      expect(calls.single.url.queryParameters, {'expectedRevision': '7'});
      expect(calls.single.body, isEmpty);
    },
  );

  test(
    'other methods, routes and secret or invalid query values never send',
    () async {
      var calls = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test'),
        client: MockClient((request) async {
          calls++;
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      for (final entry in [
        ('GET', '/admin/services/$id', {'expectedRevision': '1'}),
        ('PATCH', '/admin/services/$id', {'expectedRevision': '1'}),
        ('DELETE', '/admin/sessions/$id', {'expectedRevision': '1'}),
        ('DELETE', '/admin/services/$id/check', {'expectedRevision': '1'}),
        ('DELETE', '/admin/services/not-an-id', {'expectedRevision': '1'}),
        for (final revision in [
          '0',
          '-1',
          '1.0',
          '01',
          '9223372036854775807',
          '1\n',
        ])
          ('DELETE', '/admin/services/$id', {'expectedRevision': revision}),
        (
          'DELETE',
          '/admin/services/$id',
          {'expectedRevision': '1', 'token': 'synthetic'},
        ),
      ]) {
        await expectLater(
          api.request(entry.$1, entry.$2, queryParameters: entry.$3),
          throwsA(
            isA<LarenorServerException>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
      }
      expect(calls, 0);
    },
  );
}
