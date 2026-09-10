import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/core_ha/data/core_ha_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'core_ha_activity_models_test.dart';
import 'core_ha_models_test.dart' show target;

http.Response jsonResponse(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('history and integrity use bounded exact read-only requests', () async {
    final requests = <http.Request>[];
    final contract = historyContract();
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://synthetic.invalid/prefix'),
      client: MockClient((request) async {
        requests.add(request);
        return jsonResponse(
          requests.length < 3
              ? contract[requests.length == 1 ? 'firstPage' : 'lastPage']
                    ['response']
              : {'verification': verificationJson(compared: true)},
        );
      }),
    );
    addTearDown(transport.close);
    final api = CoreHaApi(
      transport,
      'fixture_token',
      target(),
      isCurrent: () => true,
    );
    final first = await api.history(limit: 1);
    final last = await api.history(before: first.nextBefore, limit: 1);
    final proof = await api.verifyHistory(
      checkpoint: verificationJson()['checkpoint'] as String,
    );
    expect(last.nextBefore, isNull);
    expect(proof.comparedCheckpoint, isTrue);
    expect(requests.map((request) => request.method), everyElement('GET'));
    expect(requests[0].url.queryParameters, {'limit': '1'});
    expect(requests[1].url.queryParameters, {
      'before': first.nextBefore,
      'limit': '1',
    });
    expect(requests[2].url.queryParameters, {
      'checkpoint': verificationJson()['checkpoint'],
    });
    expect(requests[0].url.path, contains('/resources/${target().id}/history'));
    expect(
      requests[2].url.path,
      '/prefix/api/v1/admin/home-assistant/${target().context.coreId}/${target().context.homeId}/history/verification',
    );
    expect(requests.every((request) => request.body.isEmpty), isTrue);
    expect(
      requests.every(
        (request) => request.headers['authorization'] == 'Bearer fixture_token',
      ),
      isTrue,
    );
  });

  test('invalid pagination and checkpoint fail before transport', () async {
    var calls = 0;
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://synthetic.invalid'),
      client: MockClient((_) async {
        calls++;
        return jsonResponse({});
      }),
    );
    addTearDown(transport.close);
    final api = CoreHaApi(
      transport,
      'fixture_token',
      target(),
      isCurrent: () => true,
    );
    for (final limit in [0, 51]) {
      await expectLater(api.history(limit: limit), invalidResponse());
    }
    await expectLater(api.history(before: 'BAD'), invalidResponse());
    await expectLater(
      api.verifyHistory(checkpoint: 'x' * 513),
      invalidResponse(),
    );
    expect(calls, 0);
  });
}
