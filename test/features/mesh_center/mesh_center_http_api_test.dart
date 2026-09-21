import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/mesh_center/data/mesh_center_management_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const accountId = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';
const coordinator = '55555555555555555555555555555555';
const router = '66666666666666666666666666666666';
const deviceId = '77777777777777777777777777777777';
const catalogId = '88888888888888888888888888888888';
const firmwareId = '99999999999999999999999999999999';
const keyId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const routeId = '55555555555555555555555555555556';
const digest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

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

int get _now => DateTime.now().toUtc().millisecondsSinceEpoch;

Map<String, dynamic> get _authority => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'homeRevision': 3,
  'accountId': accountId,
  'accountRevision': 5,
  'memberRevision': 7,
  'sessionFamilyId': family,
  'role': 'admin',
  'active': true,
  'canObserveMesh': true,
  'canUpdateMesh': true,
};

Map<String, dynamic> get _topology => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'homeRevision': 3,
  'revision': 11,
  'providerRevision': 12,
  'capturedAtMs': _now - 1000,
  'coordinator': {
    'schemaVersion': 1,
    'nodeId': coordinator,
    'revision': 13,
    'providerRevision': 14,
    'protocol': 'zigbee',
    'channel': 20,
    'firmwareVersion': '3.1.0',
    'online': true,
  },
  'borderRouters': [
    {
      'schemaVersion': 1,
      'nodeId': router,
      'revision': 15,
      'providerRevision': 16,
      'routeRevision': 17,
      'protocol': 'thread',
      'firmwareVersion': '2.0.0',
      'online': true,
    },
  ],
  'devices': [
    {
      'schemaVersion': 1,
      'deviceId': deviceId,
      'revision': 19,
      'providerRevision': 20,
      'routeRevision': 21,
      'protocol': 'zigbee',
      'manufacturer': 'Acme',
      'model': 'Lamp-A',
      'hardwareRevision': 'hw-1',
      'firmwareVersion': '1.2.0',
      'powerSource': 'mains',
      'batteryPercent': null,
      'reachable': true,
      'updating': false,
      'parentId': coordinator,
      'routeDepth': 1,
      'lastSeenAtMs': _now - 1000,
    },
  ],
};

Map<String, dynamic> get _interference => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'revision': 23,
  'providerRevision': 24,
  'capturedAtMs': _now - 1000,
  'channels': [
    {'channel': 15, 'utilizationPercent': 12, 'energyDbm': -91},
    {'channel': 20, 'utilizationPercent': 84, 'energyDbm': -48},
  ],
};

Map<String, dynamic> get _catalog => {
  'schemaVersion': 1,
  'catalogId': catalogId,
  'revision': 25,
  'providerRevision': 26,
  'generatedAtMs': _now - 1000,
  'expiresAtMs': _now + const Duration(hours: 1).inMilliseconds,
  'signingKeyId': keyId,
  'entries': [
    {
      'schemaVersion': 1,
      'firmwareId': firmwareId,
      'protocol': 'zigbee',
      'manufacturer': 'Acme',
      'model': 'Lamp-A',
      'compatibleHardwareRevisions': ['hw-1'],
      'sourceVersions': ['1.2.0'],
      'version': '1.3.0',
      'sha256': digest,
      'sizeBytes': 524288,
      'minimumBatteryPercent': 50,
      'requiresMains': false,
    },
  ],
  'signature': 'c' * 128,
};

Map<String, dynamic> get _health => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'topologyRevision': 11,
  'interferenceRevision': 23,
  'readOnly': true,
  'status': 'degraded',
  'offlineDeviceIds': <String>[],
  'lowBatteryDeviceIds': <String>[],
  'threadBorderRouterCount': 1,
  'offlineBorderRouterIds': <String>[],
  'channelAdvisory': {
    'advisory': true,
    'currentChannel': 20,
    'recommendedChannel': 15,
    'currentUtilizationPercent': 84,
    'recommendedUtilizationPercent': 12,
    'reason': 'lower_interference',
    'applied': false,
  },
};

Map<String, dynamic> get _snapshot => {
  'schemaVersion': 1,
  'authority': _authority,
  'topology': _topology,
  'interference': _interference,
  'catalog': _catalog,
  'health': _health,
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
  'topologyRevision': 11,
  'topologyProviderRevision': 12,
  'coordinatorRevision': 13,
  'deviceId': deviceId,
  'expectedDeviceRevision': 19,
  'expectedResultRevision': 20,
  'expectedProviderRevision': 20,
  'expectedRouteRevision': 21,
  'catalogId': catalogId,
  'catalogRevision': 25,
  'catalogProviderRevision': 26,
  'firmwareId': firmwareId,
  'firmwareSha256': digest,
  'targetVersion': '1.3.0',
  'expiresAtMs': _now + const Duration(minutes: 1).inMilliseconds,
  'confirmationToken': 'd' * 64,
};

Map<String, dynamic> _result(String requestId) => {
  'schemaVersion': 1,
  'requestId': requestId,
  'status': 'confirmed',
  'reason': null,
  'readbackVerified': true,
  'readback': {
    'schemaVersion': 1,
    'requestId': requestId,
    'coreId': core,
    'homeId': home,
    'deviceId': deviceId,
    'previousDeviceRevision': 19,
    'deviceRevision': 20,
    'providerRevision': 20,
    'routeRevision': 21,
    'installedVersion': '1.3.0',
    'installedSha256': digest,
    'status': 'installed',
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
  test('HTTP adapter binds exact mesh snapshot update and readback', () async {
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
          request.url.path.endsWith('/admin/mesh-center/$core/$home')) {
        return _json({'snapshot': _snapshot});
      }
      if (request.method == 'POST' && request.url.path.endsWith('/previews')) {
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
    final api = CoreMeshCenterManagementApi(
      account: account,
      routeId: routeId,
      sessionRevision: 1,
      routeRevision: 1,
      isCurrent: () => current,
    );
    final initial = await api.bootstrap();
    final snapshot = await api.load(initial.authority);
    final device = snapshot.devices.single;
    final offer = device.update!;
    final preview = await api.preview(
      snapshot.authority,
      snapshot: snapshot,
      device: device,
      firmware: offer,
    );
    final confirmed = await api.confirm(snapshot.authority, preview);
    final readback = await api.readback(
      snapshot.authority,
      requestId: preview.requestId,
    );
    expect(confirmed.isExactFor(preview), isTrue);
    expect(readback.isExactFor(preview), isTrue);
    expect(
      requests.where((value) => value.url.path.contains('mesh-center')),
      hasLength(5),
    );
    expect(
      requests
          .where((value) => value.url.path.contains('mesh-center'))
          .every(
            (value) => value.headers['authorization'] == 'Bearer ${'a' * 43}',
          ),
      isTrue,
    );
    current = false;
    await expectLater(
      api.load(snapshot.authority),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('late update callback after account retirement is discarded', () async {
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
        return _json({'snapshot': _snapshot});
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
    final api = CoreMeshCenterManagementApi(
      account: account,
      routeId: routeId,
      sessionRevision: 1,
      routeRevision: 1,
      isCurrent: () => true,
    );
    final initial = await api.bootstrap();
    final snapshot = await api.load(initial.authority);
    final pending = api.preview(
      snapshot.authority,
      snapshot: snapshot,
      device: snapshot.devices.single,
      firmware: snapshot.devices.single.update!,
    );
    await Future<void>.delayed(Duration.zero);
    await account.signOut();
    gate.complete(_json({'preview': _preview(requestId)}, 201));
    await expectLater(pending, throwsA(isA<LarenorServerException>()));
  });
}
