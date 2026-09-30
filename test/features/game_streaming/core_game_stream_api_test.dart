import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/game_streaming/data/core_game_stream_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final fixtureContext = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});
final fixtureSession = ServerSession(
  endpoint: ServerEndpoint('https://core.invalid'),
  accessToken: 'x' * 43,
  refreshToken: 'y' * 43,
  expiresAt: DateTime.utc(2026, 10),
  context: fixtureContext,
  sessionFamilyId: 'f' * 32,
  user: ServerUser(
    id: 'c' * 32,
    username: 'fixture',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
);

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> host() => {
  'schemaVersion': 2,
  'id': '7' * 32,
  'revision': 1,
  'pairingRevision': 1,
  'catalogRevision': 1,
  'name': 'Owned Sunshine fixture',
  'assurance': 'native_observed',
  'active': true,
  'codecs': ['h264', 'hevc'],
};

Map<String, Object?> app() => {
  'schemaVersion': 2,
  'id': '8' * 32,
  'hostId': '7' * 32,
  'revision': 1,
  'name': 'Desktop',
  'active': true,
};

Map<String, Object> quality() => {
  'codec': 'hevc',
  'codecId': 'a' * 32,
  'codecRevision': 1,
  'displayId': 0,
  'displayRevision': 6,
  'networkId': 'b' * 32,
  'networkRevision': 7,
  'policyId': 'c' * 32,
  'policyRevision': 8,
  'widthPixels': 1920,
  'heightPixels': 1080,
  'framesPerSecond': 60,
  'bitrateKbps': 20000,
  'frameQueueDepth': 2,
  'inputQueueDepth': 1,
  'secureSurface': true,
};

Map<String, Object> clientAuthority() => {
  'routeRevision': 4,
  'lifecycleRevision': 5,
  'displayRevision': 6,
  'networkRevision': 7,
  'policyRevision': 8,
};

Map<String, Object?> session({String state = 'open', int revision = 1}) => {
  'schemaVersion': 2,
  'id': 'b' * 32,
  'hostId': '7' * 32,
  'appId': '8' * 32,
  'revision': revision,
  'state': state,
  'expiresAt': 1788610200.0,
  'coreAuthority': {
    'accountRevision': 7,
    'hostRevision': 1,
    'pairingRevision': 1,
    'catalogRevision': 1,
    'appRevision': 1,
    'selectedQuality': quality(),
  },
  'selectedQuality': quality(),
  'clientAuthority': clientAuthority(),
};

Map<String, Object?> command({
  String state = 'authorized',
  String? result,
  String? observation,
  int? readback,
}) => {
  'schemaVersion': 2,
  'id': '9' * 32,
  'sessionId': 'b' * 32,
  'intent': 'stream',
  'state': state,
  'result': result,
  'observationKind': observation,
  'readbackRevision': readback,
  'createdAt': 1788609601.0,
  'completedAt': state == 'authorized' ? null : 1788609602.0,
};

Map<String, Object?> revocation({
  String state = 'core_retired',
  int? readbackRevision,
  String? nativeReceiptDigest,
}) => {
  'schemaVersion': 2,
  'id': 'e' * 32,
  'hostId': '7' * 32,
  'hostRevision': 2,
  'state': state,
  'readbackRevision': readbackRevision,
  'nativeReceiptDigest': nativeReceiptDigest,
  'createdAt': 1788609603.0,
  'completedAt': state == 'core_retired' ? null : 1788609604.0,
};

CoreNativePairingObservation observation() => CoreNativePairingObservation(
  receiptId: '3' * 32,
  nativeBindingId: '4' * 32,
  bindingRevision: 1,
  engineRevision: 'moonlight-12.2-b48494cb',
  hostObservationId: '5' * 32,
  name: 'Owned Sunshine fixture',
  codecs: const ['h264', 'hevc'],
  catalogRevision: 1,
  catalogDigest: 'a' * 64,
  apps: [
    CoreNativeAppObservation(
      observationId: '6' * 32,
      revision: 1,
      name: 'Desktop',
    ),
  ],
);

void main() {
  test(
    'pairing intent precedes observation and maps only opaque Core ids',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: fixtureSession.endpoint,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/pairings')) {
            return response({
              'schemaVersion': 2,
              'id': '1' * 32,
              'revision': 1,
              'state': 'pending',
              'pairingGrant': '2' * 32,
              'expiresAt': 1788610200.0,
            }, 201);
          }
          return response({
            'schemaVersion': 2,
            'host': host(),
            'apps': [app()],
            'registrationMapping': {
              'nativeReceiptId': '3' * 32,
              'hostId': '7' * 32,
              'apps': [
                {'entryIndex': 0, 'appId': '8' * 32},
              ],
            },
          });
        }),
      );
      addTearDown(transport.close);
      final api = CoreGameStreamApi(
        transport,
        fixtureSession,
        isCurrent: () => true,
      );
      final intent = await api.createPairing(
        requestKey: 'pairing-request-0001',
        accountRevision: 7,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          1788610200000,
          isUtc: true,
        ),
      );
      final registered = await api.completePairing(intent, observation());
      expect(registered.host.id, '7' * 32);
      expect(registered.mapping.single.entryIndex, 0);
      expect(requests, hasLength(2));
      expect(requests.first.body, isNot(contains('observation')));
      expect(requests.last.body, isNot(contains('address')));
      expect(requests.last.body, isNot(contains('privateKey')));
    },
  );

  test(
    'catalog session dispatch and native-observed completion stay exact',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: fixtureSession.endpoint,
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET' && request.url.path.endsWith('/hosts')) {
            return response({
              'schemaVersion': 2,
              'scope': fixtureContext.toJson(),
              'accountRevision': 7,
              'hosts': [host()],
            });
          }
          if (request.method == 'GET' && request.url.path.endsWith('/apps')) {
            return response({
              'schemaVersion': 2,
              'hostRevision': 1,
              'pairingRevision': 1,
              'catalogRevision': 1,
              'apps': [app()],
            });
          }
          if (request.url.path.endsWith('/sessions')) {
            return response(session(), 201);
          }
          if (request.url.path.endsWith('/commands')) {
            return response({
              'schemaVersion': 2,
              'command': command(),
              'dispatchGrant': 'c' * 32,
            }, 201);
          }
          return response(
            command(
              state: 'native_observed',
              result: 'streaming',
              observation: 'connectionStarted',
              readback: 12,
            ),
          );
        }),
      );
      addTearDown(transport.close);
      final api = CoreGameStreamApi(
        transport,
        fixtureSession,
        isCurrent: () => true,
      );
      final hosts = await api.hosts();
      final catalog = await api.apps(hosts.hosts.single);
      final selected = CoreGameStreamSelectedQuality.fromJson(quality());
      final opened = await api.open(
        host: catalog.host,
        app: catalog.apps.single,
        accountRevision: hosts.accountRevision,
        clientAuthority: const CoreGameStreamClientAuthority(
          routeRevision: 4,
          lifecycleRevision: 5,
          displayRevision: 6,
          networkRevision: 7,
          policyRevision: 8,
        ),
        selectedQuality: selected,
        requestKey: 'session-request-0001',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          1788610200000,
          isUtc: true,
        ),
      );
      final authorized = await api.authorize(
        opened,
        requestKey: 'command-request-0001',
        intent: 'stream',
      );
      final completed = await api.complete(
        opened,
        authorized,
        state: 'native_observed',
        result: 'streaming',
        observationKind: 'connectionStarted',
        readbackRevision: 12,
        nativeReceiptDigest: 'd' * 64,
      );
      expect(completed.state, 'native_observed');
      expect(requests, hasLength(5));
      final openBody = jsonDecode(requests[2].body) as Map<String, dynamic>;
      expect(openBody['selectedQuality'], quality());
      expect(openBody['clientAuthority'], clientAuthority());
    },
  );

  test('replayed authorization without a grant cannot be completed', () async {
    final parsedSession = CoreGameStreamSession.fromJson(session());
    final transport = LarenorServerApi(
      endpoint: fixtureSession.endpoint,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/commands')) {
          return response({
            'schemaVersion': 2,
            'command': command(
              state: 'unknown',
              result: 'unknown',
              observation: 'unknown',
            ),
            'dispatchGrant': null,
          });
        }
        fail('unexpected request');
      }),
    );
    addTearDown(transport.close);
    final api = CoreGameStreamApi(
      transport,
      fixtureSession,
      isCurrent: () => true,
    );
    final replay = await api.authorize(
      parsedSession,
      requestKey: 'command-request-0001',
      intent: 'stream',
    );
    expect(replay.dispatchGrant, isNull);
    await expectLater(
      api.complete(
        parsedSession,
        replay,
        state: 'unknown',
        result: 'unknown',
        observationKind: 'unknown',
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('native rejection requires the causal readback accepted by Core', () {
    final observed = command(
      state: 'rejected',
      result: 'rejected',
      observation: 'nativeRejected',
      readback: 17,
    );
    expect(
      CoreGameStreamCommand.fromJson(
        observed,
        sessionId: 'b' * 32,
        expectedIntent: 'stream',
      ).readbackRevision,
      17,
    );
    observed['readbackRevision'] = null;
    expect(
      () => CoreGameStreamCommand.fromJson(
        observed,
        sessionId: 'b' * 32,
        expectedIntent: 'stream',
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test(
    'revocation completion sends and requires causal native evidence',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: fixtureSession.endpoint,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/revoke')) {
            return response(revocation(), 201);
          }
          if (request.url.path.endsWith('/complete')) {
            return response(
              revocation(
                state: 'local_cleared',
                readbackRevision: 13,
                nativeReceiptDigest: 'd' * 64,
              ),
            );
          }
          fail('unexpected request');
        }),
      );
      addTearDown(transport.close);
      final api = CoreGameStreamApi(
        transport,
        fixtureSession,
        isCurrent: () => true,
      );
      final parsedHost = CoreGameStreamHost.fromJson(host());
      final retired = await api.revoke(
        parsedHost,
        requestKey: 'revoke-request-0001',
      );
      final cleared = await api.completeRevocation(
        retired,
        state: 'local_cleared',
        readbackRevision: 13,
        nativeReceiptDigest: 'd' * 64,
      );
      expect(cleared.readbackRevision, 13);
      expect(cleared.nativeReceiptDigest, 'd' * 64);
      expect(jsonDecode(requests.last.body), {
        'schemaVersion': 2,
        'state': 'local_cleared',
        'readbackRevision': 13,
        'nativeReceiptDigest': 'd' * 64,
      });
      await expectLater(
        api.completeRevocation(
          retired,
          state: 'unknown',
          readbackRevision: 14,
          nativeReceiptDigest: 'e' * 64,
        ),
        throwsA(isA<LarenorServerException>()),
      );
      expect(requests, hasLength(2));
    },
  );

  test('unsafe revision and late response fail closed', () async {
    var current = true;
    final pending = Completer<http.Response>();
    final transport = LarenorServerApi(
      endpoint: fixtureSession.endpoint,
      client: MockClient((_) => pending.future),
    );
    addTearDown(transport.close);
    final api = CoreGameStreamApi(
      transport,
      fixtureSession,
      isCurrent: () => current,
    );
    final future = api.hosts();
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete(
      response({
        'schemaVersion': 2,
        'scope': fixtureContext.toJson(),
        'accountRevision': gameStreamMaxSafeInteger + 1,
        'hosts': <Object>[],
      }),
    );
    await expectLater(future, throwsA(isA<LarenorServerException>()));
  });
}
