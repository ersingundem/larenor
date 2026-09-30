import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  const coreId = '11111111111111111111111111111111';
  const homeId = '22222222222222222222222222222222';
  const profileId = '33333333333333333333333333333333';
  const requestId = '44444444444444444444444444444444';
  const path = '/core-remote-profiles/$coreId/$homeId/$profileId';
  const query = {
    'requestId': requestId,
    'expectedRevision': '5',
    'expectedAccountRevision': '7',
    'expectedCollectionRevision': '11',
  };

  test('exact Core profile DELETE query reaches transport once', () async {
    final calls = <http.Request>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://server.test/prefix'),
      client: MockClient((request) async {
        calls.add(request);
        return http.Response(
          jsonEncode({'deleted': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    await api.request('DELETE', path, queryParameters: query);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'DELETE');
    expect(
      calls.single.url.path,
      '/prefix/api/v1/core-remote-profiles/$coreId/$homeId/$profileId',
    );
    expect(calls.single.url.queryParameters, query);
  });

  test('foreign, extra, duplicate and stale queries never send', () async {
    var calls = 0;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://server.test'),
      client: MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);

    for (final candidate in <(String, String, Map<String, String>)>[
      ('GET', path, query),
      ('POST', path, query),
      ('DELETE', '$path/foreign', query),
      (
        'DELETE',
        '/core-remote-profiles/$coreId/$homeId/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        query,
      ),
      ('DELETE', '$path?requestId=$requestId', query),
      ('DELETE', path, {...query, 'extra': '1'}),
      ('DELETE', path, {...query, 'requestId': 'foreign'}),
      ('DELETE', path, {...query, 'expectedRevision': '0'}),
      ('DELETE', path, {...query, 'expectedAccountRevision': '07'}),
      ('DELETE', path, {...query, 'expectedCollectionRevision': '-1'}),
    ]) {
      await expectLater(
        api.request(candidate.$1, candidate.$2, queryParameters: candidate.$3),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_request',
          ),
        ),
      );
    }
    expect(calls, 0);
  });
}
