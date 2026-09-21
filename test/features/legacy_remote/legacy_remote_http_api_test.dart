import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/legacy_remote/data/legacy_remote_management_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const accountId = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';
const deviceId = '55555555555555555555555555555555';
const bridge = '66666666666666666666666666666666';
const provider = '77777777777777777777777777777777';
const profile = '88888888888888888888888888888888';
const codeSet = '99999999999999999999999999999999';
const binding = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const routeId = '56565656565656565656565656565656';

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

Map<String, dynamic> get _authority => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'homeRevision': 3,
  'accountId': accountId,
  'accountRevision': 5,
  'memberRevision': 7,
  'sessionFamilyId': family,
  'active': true,
  'canControlLegacyRemote': true,
};

Map<String, dynamic> get _catalog => {
  'schemaVersion': 1,
  'authority': _authority,
  'items': [
    {
      'schemaVersion': 1,
      'name': 'Living room TV',
      'device': {
        'schemaVersion': 1,
        'coreId': core,
        'homeId': home,
        'deviceId': deviceId,
        'revision': 11,
        'providerType': 'home_assistant',
        'providerId': provider,
        'providerRevision': 13,
        'bridgeId': bridge,
        'bridgeRevision': 17,
        'protocol': 'ir',
        'stored': true,
        'reachable': true,
        'providerVerified': true,
      },
      'profile': {
        'schemaVersion': 1,
        'coreId': core,
        'homeId': home,
        'profileId': profile,
        'revision': 19,
        'deviceId': deviceId,
        'expectedDeviceRevision': 11,
        'providerId': provider,
        'expectedProviderRevision': 13,
        'codeSetId': codeSet,
        'codeSetRevision': 23,
        'protocol': 'ir',
        'commands': [
          {
            'schemaVersion': 1,
            'bindingId': binding,
            'key': 'power_toggle',
            'maxRepeats': 1,
            'maxHoldMs': 0,
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> _preview(String requestId) => {
  'schemaVersion': 1,
  'requestId': requestId,
  'coreId': core,
  'homeId': home,
  'homeRevision': 3,
  'accountId': accountId,
  'accountRevision': 5,
  'memberRevision': 7,
  'sessionFamilyId': family,
  'deviceId': deviceId,
  'deviceRevision': 11,
  'providerType': 'home_assistant',
  'providerId': provider,
  'providerRevision': 13,
  'bridgeId': bridge,
  'bridgeRevision': 17,
  'profileId': profile,
  'profileRevision': 19,
  'codeSetId': codeSet,
  'codeSetRevision': 23,
  'bindingId': binding,
  'key': 'power_toggle',
  'repeats': 1,
  'holdMs': 0,
  'expiresAtMs': DateTime.now()
      .add(const Duration(minutes: 1))
      .millisecondsSinceEpoch,
  'confirmationToken': 'c' * 64,
};

Map<String, dynamic> _result(String requestId) => {
  'schemaVersion': 1,
  'requestId': requestId,
  'status': 'dispatched',
  'reason': null,
  'deliveryVerified': true,
  'deviceStateVerified': false,
  'receipt': {
    'schemaVersion': 1,
    'requestId': requestId,
    'coreId': core,
    'homeId': home,
    'providerId': provider,
    'providerRevision': 13,
    'bridgeId': bridge,
    'bridgeRevision': 17,
    'deviceId': deviceId,
    'deviceRevision': 11,
    'profileId': profile,
    'profileRevision': 19,
    'codeSetId': codeSet,
    'codeSetRevision': 23,
    'bindingId': binding,
    'key': 'power_toggle',
    'repeats': 1,
    'holdMs': 0,
    'status': 'emitted',
  },
};

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

void main() {
  test(
    'authenticated HTTP adapter binds exact catalog preview and readback',
    () async {
      final requests = <http.Request>[];
      late String requestId;
      final account = await _account((request) async {
        requests.add(request);
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
        if (request.method == 'GET' &&
            request.url.path.endsWith('/admin/legacy-remotes/$core/$home')) {
          return _json({'catalog': _catalog});
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/previews')) {
          requestId = (jsonDecode(request.body) as Map)['requestId'] as String;
          return _json({'preview': _preview(requestId)}, 201);
        }
        if (request.method == 'POST' && request.url.path.endsWith('/confirm')) {
          return _json({'result': _result(requestId)});
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/results/$requestId')) {
          return _json({'result': _result(requestId)});
        }
        throw StateError(
          'unexpected route ${request.method} ${request.url.path}',
        );
      });
      addTearDown(account.dispose);
      var current = true;
      final api = CoreLegacyRemoteManagementApi(
        account: account,
        routeId: routeId,
        sessionRevision: 1,
        routeRevision: 1,
        isCurrent: () => current,
      );
      final catalog = await api.bootstrap();
      final devices = await api.list(catalog.authority);
      final device = devices.single;
      final command = device.commands.single;
      final preview = await api.preview(
        catalog.authority,
        device: device,
        command: command,
        repeats: 1,
        holdMs: 0,
      );
      final confirmed = await api.confirm(catalog.authority, preview);
      final readback = await api.readback(
        catalog.authority,
        requestId: preview.requestId,
      );
      expect(confirmed.isExactFor(preview), isTrue);
      expect(readback.isExactFor(preview), isTrue);
      expect(
        requests.where((value) => value.url.path.contains('legacy-remotes')),
        hasLength(5),
      );
      expect(
        requests
            .where((value) => value.url.path.contains('legacy-remotes'))
            .every(
              (value) => value.headers['authorization'] == 'Bearer ${'a' * 43}',
            ),
        isTrue,
      );
      current = false;
      expect(
        () => api.list(catalog.authority),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );

  test('late HTTP callback after account retirement is discarded', () async {
    final gate = Completer<http.Response>();
    var requestId = '';
    final account = await _account((request) async {
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
      if (request.method == 'GET' && request.url.path.endsWith('/$home')) {
        return _json({'catalog': _catalog});
      }
      if (request.method == 'POST' && request.url.path.endsWith('/previews')) {
        requestId = (jsonDecode(request.body) as Map)['requestId'] as String;
        return gate.future;
      }
      if (request.url.path.endsWith('/auth/logout')) {
        return http.Response('', 204);
      }
      throw StateError('unexpected route');
    });
    addTearDown(account.dispose);
    final api = CoreLegacyRemoteManagementApi(
      account: account,
      routeId: routeId,
      sessionRevision: 1,
      routeRevision: 1,
      isCurrent: () => true,
    );
    final catalog = await api.bootstrap();
    final devices = await api.list(catalog.authority);
    final pending = api.preview(
      catalog.authority,
      device: devices.single,
      command: devices.single.commands.single,
      repeats: 1,
      holdMs: 0,
    );
    await Future<void>.delayed(Duration.zero);
    await account.signOut();
    gate.complete(_json({'preview': _preview(requestId)}, 201));
    await expectLater(pending, throwsA(isA<LarenorServerException>()));
  });
}
