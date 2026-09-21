import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/sound_events/data/core_sound_event_api.dart';
import 'package:larenor/features/sound_events/domain/sound_event_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const accountId = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';
const room = '55555555555555555555555555555555';
const device = '66666666666666666666666666666666';
const eventId = '77777777777777777777777777777777';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Future<ServerAccountController> _account(
  Future<http.Response> Function(http.Request) handler,
) async {
  final account = ServerAccountController(
    store: _Store(),
    apiFactory: (endpoint) =>
        LarenorServerApi(endpoint: endpoint, client: MockClient(handler)),
  );
  await account.signIn(
    baseUrl: 'https://core.invalid',
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'tablet',
  );
  return account;
}

Map<String, Object> _snapshot({
  int repositoryRevision = 2,
  int eventRevision = 1,
  bool acknowledged = false,
  String sessionFamilyId = family,
}) => {
  'schemaVersion': 1,
  'authority': {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
    'accountId': accountId,
    'sessionFamilyId': sessionFamilyId,
    'accountRevision': 1,
    'repositoryRevision': repositoryRevision,
    'canRead': true,
    'canAcknowledge': true,
  },
  'repositoryRevision': repositoryRevision,
  'events': [
    {
      'schemaVersion': 1,
      'eventId': eventId,
      'roomId': room,
      'deviceId': device,
      'className': 'bark',
      'confidence': .91,
      'observedAtMs': 10000,
      'retentionExpiresAtMs': 10000000000000,
      'eventRevision': eventRevision,
      'acknowledged': acknowledged,
      'automationVerified': true,
    },
  ],
};

Future<http.Response> _sessionRoutes(http.Request request) async {
  if (request.url.path.endsWith('/auth/login')) {
    return _json({
      'accessToken': 'a' * 43,
      'refreshToken': 'b' * 43,
      'expiresIn': 3600,
      'user': {
        'id': accountId,
        'username': 'admin',
        'role': 'admin',
        'mustChangePassword': false,
      },
    });
  }
  if (request.url.path.endsWith('/context')) {
    return _json({'schemaVersion': 1, 'coreId': core, 'homeId': home});
  }
  throw StateError('unexpected session route ${request.url.path}');
}

void main() {
  test(
    'HTTP adapter binds acknowledgement to exact authenticated readback',
    () async {
      final requests = <http.Request>[];
      var acknowledged = false;
      late String requestId;
      final account = await _account((request) async {
        if (request.url.path.endsWith('/auth/login') ||
            request.url.path.endsWith('/context')) {
          return _sessionRoutes(request);
        }
        requests.add(request);
        if (request.method == 'GET') {
          return _json(
            _snapshot(
              repositoryRevision: acknowledged ? 3 : 2,
              eventRevision: acknowledged ? 2 : 1,
              acknowledged: acknowledged,
            ),
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requestId = body['requestId'] as String;
        expect(body['expectedRepositoryRevision'], 2);
        expect(body['expectedEventRevision'], 1);
        acknowledged = true;
        return _json({
          'schemaVersion': 1,
          'requestId': requestId,
          'eventId': eventId,
          'coreId': core,
          'homeId': home,
          'accountId': accountId,
          'sessionFamilyId': family,
          'repositoryRevision': 3,
          'eventRevision': 2,
          'acknowledged': true,
        });
      });
      addTearDown(account.dispose);
      final api = CoreSoundEventApi(
        account: account,
        isCurrent: () => true,
        random: Random(7),
      );
      final before = await api.bootstrap();
      final receipt = await api.acknowledge(
        before.authority,
        before,
        before.events.single,
      );
      final after = await api.load(
        before.authority.withRepositoryRevision(receipt.repositoryRevision),
        const SoundEventFilter(),
      );
      expect(after.events.single.acknowledged, isTrue);
      expect(
        receipt.exactFor(before.authority, before, before.events.single),
        isTrue,
      );
      expect(requestId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(requests, hasLength(3));
      expect(
        requests.every(
          (request) => request.headers['authorization'] == 'Bearer ${'a' * 43}',
        ),
        isTrue,
      );
    },
  );

  test('foreign family revision response fails closed', () async {
    var requestCount = 0;
    final account = await _account((request) async {
      if (request.url.path.endsWith('/auth/login') ||
          request.url.path.endsWith('/context')) {
        return _sessionRoutes(request);
      }
      requestCount++;
      return _json(
        _snapshot(sessionFamilyId: requestCount == 1 ? family : 'f' * 32),
      );
    });
    addTearDown(account.dispose);
    final api = CoreSoundEventApi(account: account, isCurrent: () => true);
    final initial = await api.bootstrap();
    await expectLater(
      api.load(initial.authority, const SoundEventFilter()),
      throwsA(isA<LarenorServerException>()),
    );
    expect(api.boundSession, isNull);
  });

  test('late snapshot after route retirement is discarded', () async {
    final gate = Completer<http.Response>();
    final account = await _account((request) async {
      if (request.url.path.endsWith('/auth/login') ||
          request.url.path.endsWith('/context')) {
        return _sessionRoutes(request);
      }
      return gate.future;
    });
    addTearDown(account.dispose);
    var current = true;
    final api = CoreSoundEventApi(account: account, isCurrent: () => current);
    final pending = api.bootstrap();
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete(_json(_snapshot()));
    await expectLater(pending, throwsA(isA<LarenorServerException>()));
    expect(api.boundSession, isNull);
  });
}
