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
      'routeKnown': true,
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
  'interferenceAvailable': true,
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
  'coordinatorBackup': {
    'schemaVersion': 1,
    'backupId': 'd' * 32,
    'coreId': core,
    'homeId': home,
    'coordinatorNodeId': coordinator,
    'coordinatorRevision': 13,
    'providerRevision': 14,
    'capturedAtMs': _now - 2000,
    'artifactSha256': digest,
    'encrypted': true,
    'integrityVerified': true,
    'restorable': true,
  },
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

Map<String, dynamic> get _managedTopology => {
  ..._topology,
  'revision': 22,
  'providerRevision': 22,
  'capturedAtMs': _now - 500,
  'devices': [
    {
      ...(_topology['devices'] as List).single as Map<String, dynamic>,
      'revision': 22,
      'providerRevision': 22,
      'routeRevision': 22,
      'firmwareVersion': null,
      'powerSource': 'battery',
      'batteryPercent': 84,
      'routeKnown': false,
      'parentId': null,
      'routeDepth': null,
    },
  ],
};

Map<String, dynamic> get _managedSnapshot => {
  ..._snapshot,
  'topology': _managedTopology,
  'catalog': {
    ..._catalog,
    'revision': 22,
    'providerRevision': 22,
    'entries': [],
  },
  'interference': {..._interference, 'revision': 22, 'providerRevision': 22},
  'health': {
    ..._health,
    'topologyRevision': 22,
    'interferenceRevision': 22,
    'interferenceAvailable': false,
    'channelAdvisory': null,
  },
};

Map<String, dynamic> get _managedOffer => {
  'schemaVersion': 1,
  'offerId': 'e' * 32,
  'provider': 'zigbee2mqtt',
  'coreId': core,
  'homeId': home,
  'deviceId': deviceId,
  'topologyRevision': 22,
  'providerRevision': 22,
  'deviceRevision': 22,
  'installedFileVersion': 5,
  'latestFileVersion': 10,
  'providerSourceDigest': 'f' * 64,
  'checkedAtMs': _now - 200,
  'expiresAtMs': _now + const Duration(minutes: 5).inMilliseconds,
  'releaseNotesAvailable': true,
};

Map<String, dynamic> _managedPreview(String requestId) => {
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
  'topologyRevision': 22,
  'providerRevision': 22,
  'deviceRevision': 22,
  'offerId': 'e' * 32,
  'installedFileVersion': 5,
  'latestFileVersion': 10,
  'providerSourceDigest': 'f' * 64,
  'expiresAtMs': _now + const Duration(minutes: 2).inMilliseconds,
  'confirmationToken': 'a' * 64,
};

Map<String, dynamic> _managedResult(String requestId) => {
  'schemaVersion': 1,
  'requestId': requestId,
  'status': 'confirmed',
  'reason': 'installed',
  'readbackVerified': true,
  'previousProviderRevision': 22,
  'providerRevision': 23,
  'installedFileVersion': 10,
  'completedAtMs': _now,
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
    'HTTP adapter completes provider-managed OTA without firmware input',
    () async {
      var checked = false;
      var requestId = '';
      var resultReads = 0;
      final requests = <http.Request>[];
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
          return _json({'snapshot': checked ? _managedSnapshot : _snapshot});
        }
        if (request.url.path.endsWith('/managed-ota/checks')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.keys, containsAll(['authority', 'topology', 'deviceId']));
          expect(body.containsKey('url'), isFalse);
          expect(body.containsKey('image'), isFalse);
          checked = true;
          return _json({'offer': _managedOffer});
        }
        if (request.url.path.endsWith('/managed-ota/previews')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requestId = body['requestId'] as String;
          expect((body['offer'] as Map).containsKey('url'), isFalse);
          return _json({'preview': _managedPreview(requestId)}, 201);
        }
        if (request.method == 'POST' && request.url.path.endsWith('/confirm')) {
          return _json({'result': _managedResult(requestId)});
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/managed-ota/results/$requestId')) {
          resultReads++;
          if (resultReads == 1) {
            return _json({
              'error': {'code': 'mesh_update_in_progress'},
            }, 409);
          }
          return _json({'result': _managedResult(requestId)});
        }
        throw StateError(
          'unexpected route ${request.method} ${request.url.path}',
        );
      });
      addTearDown(account.dispose);
      final api = CoreMeshCenterManagementApi(
        account: account,
        routeId: routeId,
        sessionRevision: 1,
        routeRevision: 1,
        isCurrent: () => true,
        delay: (_) async {},
      );
      final initial = await api.bootstrap();
      final before = await api.load(initial.authority);
      final availability = await api.checkManagedOta(
        before.authority,
        snapshot: before,
        device: before.devices.single,
      );
      expect(availability.device.routeKnown, isFalse);
      expect(availability.offer.latestFileVersion, 10);
      final preview = await api.previewManagedOta(
        before.authority,
        availability,
      );
      final confirmed = await api.confirmManagedOta(before.authority, preview);
      final readback = await api.awaitManagedOtaResult(
        before.authority,
        requestId: preview.requestId,
      );
      expect(confirmed.isExactFor(preview), isTrue);
      expect(readback.isExactFor(preview), isTrue);
      expect(
        requests
            .where((value) => value.url.path.contains('managed-ota'))
            .length,
        5,
      );
      expect(resultReads, 2);
    },
  );

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
    expect(snapshot.coordinatorBackup?.restorable, isTrue);
    expect(snapshot.coordinatorBackup?.integrityVerified, isTrue);
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
