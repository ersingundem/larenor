import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/data/home_resources_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_resources_fixture.dart';

void main() {
  test('actual HTTP pages use scoped identity, opaque snapshot and requested limit', () async {
    final h = ResourceHarness();
    final firstRaw = h.fixture['firstPage'];
    final client = LarenorServerApi(
      endpoint: ServerEndpoint('https://synthetic.invalid/prefix'),
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer synthetic');
        expect(
          request.url.path,
          '/prefix/api/v1/home-resources/${'a' * 32}/${'b' * 32}',
        );
        expect(request.url.queryParameters['limit'], '1');
        if (request.url.queryParameters.containsKey('after')) {
          expect(request.url.queryParameters['after'], firstRaw['nextAfter']);
          expect(
            request.url.queryParameters['expectedSnapshot'],
            firstRaw['snapshot'],
          );
          return h.json(h.fixture['secondPage']);
        }
        return h.json(firstRaw);
      }),
    );
    addTearDown(client.close);
    final api = HomeResourcesApi(
      client,
      'synthetic',
      ServerContext.fromJson(h.fixture['context']),
    );
    final first = await api.list(limit: 1);
    final second = await api.list(
      limit: 1,
      after: first.nextAfter,
      snapshot: first.snapshot,
    );
    expect(first.entries.single.id, firstRaw['entries'][0]['ref']['id']);
    expect(
      second.entries.single.id,
      h.fixture['secondPage']['entries'][0]['ref']['id'],
    );
  });
  for (final mode in ['tooMany', 'wrongScope', 'staleSnapshot', 'private500']) {
    test('rejects $mode safely without another request', () async {
      final h = ResourceHarness();
      var calls = 0;
      final client = LarenorServerApi(
        endpoint: ServerEndpoint('https://synthetic.invalid'),
        client: MockClient((_) async {
          calls++;
          return switch (mode) {
            'tooMany' => h.json(h.fixture['adminList']),
            'wrongScope' => h.json(h.fixture['otherContextList']),
            'staleSnapshot' => h.json(h.fixture['stalePageError'], 409),
            _ => h.json({
              'error': {'code': 'private-secret', 'message': 'private-secret'},
            }, 500),
          };
        }),
      );
      addTearDown(client.close);
      final api = HomeResourcesApi(
        client,
        'synthetic',
        ServerContext.fromJson(h.fixture['context']),
      );
      await expectLater(
        api.list(limit: 1),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'safe code',
            mode == 'staleSnapshot'
                ? 'revision_conflict'
                : mode == 'private500'
                ? 'server_error'
                : 'invalid_response',
          ),
        ),
      );
      expect(calls, 1);
    });
  }
}
