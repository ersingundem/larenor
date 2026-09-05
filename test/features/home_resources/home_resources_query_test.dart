import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  test(
    'exact home-resource GET accepts canonical scoped snapshot continuation',
    () async {
      var calls = 0;
      final path = '/home-resources/${'a' * 32}/${'b' * 32}';
      final query = {
        'limit': '25',
        'after': 'c' * 32,
        'expectedSnapshot': 'd' * 64,
      };
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://synthetic.invalid/core'),
        client: MockClient((request) async {
          calls++;
          expect(request.method, 'GET');
          expect(request.url.path, '/core/api/v1$path');
          expect(request.url.queryParameters, query);
          expect(request.headers['authorization'], 'Bearer synthetic-token');
          expect(request.followRedirects, isFalse);
          return http.Response(
            jsonEncode({'synthetic': true}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.close);
      expect(
        await api.request(
          'GET',
          path,
          token: 'synthetic-token',
          queryParameters: query,
        ),
        {'synthetic': true},
      );
      expect(calls, 1);
    },
  );
  for (final query in [
    {'after': 'c' * 32},
    {'limit': '0'},
    {'limit': '101'},
    {'limit': '01'},
    {'userId': 'c' * 32},
    {'after': 'C' * 32, 'expectedSnapshot': 'd' * 64},
    {'after': 'c' * 32, 'expectedSnapshot': 'D' * 64},
    {'after': 'c' * 32, 'expectedSnapshot': 'd' * 65},
  ]) {
    test(
      'invalid scoped query never reaches transport ${query.keys.join('/')}/${query.values.first.length}',
      () async {
        var calls = 0;
        final api = LarenorServerApi(
          endpoint: ServerEndpoint('https://synthetic.invalid'),
          client: MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }),
        );
        addTearDown(api.close);
        await expectLater(
          api.request(
            'GET',
            '/home-resources/${'a' * 32}/${'b' * 32}',
            queryParameters: query,
          ),
          throwsA(
            isA<LarenorServerException>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        expect(calls, 0);
      },
    );
  }
}
