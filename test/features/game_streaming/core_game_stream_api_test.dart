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
  user: ServerUser(
    id: 'c' * 32,
    username: 'fixture',
    role: ServerRole.member,
    mustChangePassword: false,
  ),
);

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> host() => {
  'schemaVersion': 1,
  'ref': {
    ...fixtureContext.toJson(),
    'kind': 'game_stream_host',
    'id': 'd' * 32,
  },
  'revision': 2,
  'name': 'Gaming PC',
  'pairingRevision': 3,
  'active': true,
  'codecs': ['h264', 'hevc'],
  'maxWidth': 3840,
  'maxHeight': 2160,
  'maxFps': 120,
};

Map<String, int> authority() => {
  'expectedHostRevision': 2,
  'expectedPairingRevision': 3,
  'accountRevision': 4,
  'routeRevision': 5,
  'lifecycleRevision': 6,
  'displayRevision': 7,
  'networkRevision': 8,
  'policyRevision': 9,
};

Map<String, Object?> lease() => {
  'schemaVersion': 1,
  'id': 'e' * 32,
  'hostId': 'd' * 32,
  'revision': 1,
  'state': 'open',
  'expiresAt': 1790812800.0,
  'authority': authority(),
};

Map<String, Object?> command({String state = 'authorized', int? readback}) => {
  'schemaVersion': 1,
  'id': 'f' * 32,
  'sessionId': 'e' * 32,
  'intent': 'stream',
  'state': state,
  'result': state == 'verified' ? 'streaming' : null,
  'readbackRevision': readback,
  'createdAt': 1788609600.0,
  'completedAt': state == 'verified' ? 1788609601.0 : null,
};

void main() {
  test('host lease and command receipts stay exact and secret free', () async {
    final requests = <http.Request>[];
    final transport = LarenorServerApi(
      endpoint: fixtureSession.endpoint,
      client: MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], 'Bearer ${'x' * 43}');
        if (request.method == 'GET') {
          return response({
            'schemaVersion': 1,
            'scope': fixtureContext.toJson(),
            'accountRevision': 4,
            'hosts': [host()],
          });
        }
        if (request.url.path.endsWith('/sessions')) {
          return response(lease(), 201);
        }
        if (request.url.path.endsWith('/complete')) {
          return response(command(state: 'verified', readback: 10));
        }
        return response(command(), 201);
      }),
    );
    addTearDown(transport.close);
    final api = CoreGameStreamApi(
      transport,
      fixtureSession,
      isCurrent: () => true,
    );
    final hosts = await api.hosts();
    final opened = await api.open(
      host: hosts.hosts.single,
      accountRevision: hosts.accountRevision,
      routeRevision: 5,
      lifecycleRevision: 6,
      displayRevision: 7,
      networkRevision: 8,
      policyRevision: 9,
      requestKey: 'session-request-0001',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        1790812800000,
        isUtc: true,
      ),
    );
    final authorized = await api.authorize(
      opened,
      requestKey: 'command-request-0001',
      intent: 'stream',
    );
    final verified = await api.complete(
      opened,
      authorized,
      state: 'verified',
      result: 'streaming',
      readbackRevision: 10,
    );
    expect(verified.readbackRevision, 10);
    expect(requests, hasLength(4));
    expect(
      requests.every((item) => !item.body.toLowerCase().contains('credential')),
      isTrue,
    );
  });

  test('foreign scope and malformed capability response fail closed', () async {
    final transport = LarenorServerApi(
      endpoint: fixtureSession.endpoint,
      client: MockClient(
        (_) async => response({
          'schemaVersion': 1,
          'scope': {...fixtureContext.toJson(), 'homeId': '0' * 32},
          'accountRevision': 4,
          'hosts': [host()],
        }),
      ),
    );
    addTearDown(transport.close);
    final api = CoreGameStreamApi(
      transport,
      fixtureSession,
      isCurrent: () => true,
    );
    await expectLater(api.hosts(), throwsA(isA<LarenorServerException>()));
  });

  test(
    'late HTTP completion is cancelled when route authority retires',
    () async {
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
          'schemaVersion': 1,
          'scope': fixtureContext.toJson(),
          'accountRevision': 4,
          'hosts': [host()],
        }),
      );
      await expectLater(
        future,
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
  );
}
