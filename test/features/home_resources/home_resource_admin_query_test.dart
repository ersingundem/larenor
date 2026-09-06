import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  final path = '/admin/home-resources/${'a' * 32}/${'b' * 32}/${'c' * 32}';
  final valid = {
    'expectedRevision': '1',
    'expectedAclRevision': '9223372036854775807',
  };
  test(
    'public transport permits exactly both canonical revision queries',
    () async {
      var calls = 0;
      final client = LarenorServerApi(
        endpoint: ServerEndpoint('https://synthetic.invalid'),
        client: MockClient((request) async {
          calls++;
          expect(request.url.queryParameters, valid);
          return http.Response('', 204);
        }),
      );
      addTearDown(client.close);
      expect(
        await client.request(
          'DELETE',
          path,
          token: 'synthetic',
          queryParameters: valid,
          allowEmpty: true,
        ),
        isNull,
      );
      expect(calls, 1);
    },
  );
  final rejected = <(String, Map<String, String>?)>[
    (path, null),
    (path, {}),
    (path, {'expectedRevision': '1'}),
    (path, {'expectedAclRevision': '1'}),
    (path, {...valid, 'extra': '1'}),
    (path.replaceFirst('a' * 32, 'a' * 31), valid),
    (path.replaceFirst('b' * 32, 'B' * 32), valid),
    ('$path/extra', valid),
    ('$path\n', valid),
    ('/admin/home-resources', valid),
    ('/admin/services/${'a' * 32}', valid),
    for (final key in valid.keys)
      for (final value in [
        '0',
        '-1',
        '01',
        '+1',
        ' 1',
        '1 ',
        '1.0',
        'true',
        '9223372036854775808',
        '1\n',
      ])
        (path, {...valid, key: value}),
  ];
  for (var i = 0; i < rejected.length; i++) {
    test('invalid query/route $i performs zero HTTP', () async {
      var calls = 0;
      final client = LarenorServerApi(
        endpoint: ServerEndpoint('https://synthetic.invalid'),
        client: MockClient((_) async {
          calls++;
          return http.Response('', 204);
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.request(
          'DELETE',
          rejected[i].$1,
          token: 'synthetic',
          queryParameters: rejected[i].$2,
          allowEmpty: true,
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
    });
  }
  test('existing service forget stays single-revision only', () async {
    var calls = 0;
    final client = LarenorServerApi(
      endpoint: ServerEndpoint('https://synthetic.invalid'),
      client: MockClient((request) async {
        calls++;
        expect(request.url.queryParameters, {'expectedRevision': '1'});
        return http.Response('', 204);
      }),
    );
    addTearDown(client.close);
    await client.request(
      'DELETE',
      '/admin/services/${'a' * 32}',
      queryParameters: {'expectedRevision': '1'},
      allowEmpty: true,
    );
    expect(calls, 1);
  });
}
