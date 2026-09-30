import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_profiles/data/camera_profile_api.dart';
import 'package:larenor/features/camera_profiles/domain/camera_profile_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _accountId = '33333333333333333333333333333333';
const _family = '44444444444444444444444444444444';
const _profile = '55555555555555555555555555555555';
const _camera1 = '66666666666666666666666666666666';
const _area1 = '77777777777777777777777777777777';
const _source = '88888888888888888888888888888888';
const _service1 = '99999999999999999999999999999999';
const _binding1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _camera2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _area2 = 'cccccccccccccccccccccccccccccccc';
const _service2 = 'dddddddddddddddddddddddddddddddd';
const _binding2 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _access = 'camera_profile_access_token_123456789012345';
const _refresh = 'camera_profile_refresh_token_12345678901234';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _ProfileCore {
  _ProfileCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  int loginCalls = 0, snapshotCalls = 0, applyCalls = 0, rollbackCalls = 0;
  String? applyRequestId, rollbackOriginalRequestId;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_ProfileCore> start() async =>
      _ProfileCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'POST' && request.uri.path == '/api/v1/auth/login') {
      loginCalls++;
      await _body(request);
      return _json(request, {
        'accessToken': _access,
        'refreshToken': _refresh,
        'expiresIn': 3600,
        'sessionFamilyId': _family,
        'user': {
          'id': _accountId,
          'username': 'admin',
          'role': 'admin',
          'mustChangePassword': false,
        },
      });
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_access') {
      return _error(request, 401);
    }
    if (request.method == 'GET' && request.uri.path == '/api/v1/context') {
      return _json(request, {
        'schemaVersion': 1,
        'coreId': _core,
        'homeId': _home,
      });
    }
    final root = '/api/v1/admin/camera-profiles/$_core/$_home';
    if (request.method == 'GET' && request.uri.path == root) {
      snapshotCalls++;
      return _json(request, {'snapshot': _snapshot()});
    }
    if (request.method == 'POST' && request.uri.path == '$root/apply') {
      applyCalls++;
      final body = await _body(request);
      applyRequestId = body['requestId'] as String?;
      if (body['schemaVersion'] != 1 ||
          body['authority'].toString() != _authority().toString() ||
          applyRequestId?.length != 32) {
        return _error(request, 400);
      }
      const command1 = '10101010101010101010101010101010';
      const command2 = '20202020202020202020202020202020';
      return _json(request, {
        'receipt': {
          'schemaVersion': 1,
          'requestId': applyRequestId,
          'profileId': _profile,
          'profileRevision': 3,
          'status': 'partial',
          'createdAtMs': 1001,
          'results': [
            {
              'schemaVersion': 1,
              'commandId': command1,
              'cameraId': _camera1,
              'status': 'applied',
              'code': 'applied',
              'readback': _commandReadback(
                command1,
                _scope1(),
                7,
                _modeHome(),
                1001,
              ),
            },
            {
              'schemaVersion': 1,
              'commandId': command2,
              'cameraId': _camera2,
              'status': 'unknown',
              'code': 'worker_ack_unknown',
              'readback': null,
            },
          ],
        },
      });
    }
    if (request.method == 'POST' && request.uri.path == '$root/rollback') {
      rollbackCalls++;
      final body = await _body(request);
      rollbackOriginalRequestId = body['originalRequestId'] as String?;
      final requestId = body['requestId'] as String?;
      if (rollbackOriginalRequestId != applyRequestId ||
          requestId?.length != 32) {
        return _error(request, 409);
      }
      const command1 = '30303030303030303030303030303030';
      const command2 = '40404040404040404040404040404040';
      return _json(request, {
        'rollbackReceipt': {
          'schemaVersion': 1,
          'requestId': requestId,
          'originalRequestId': applyRequestId,
          'profileId': _profile,
          'profileRevision': 3,
          'status': 'restored',
          'createdAtMs': 1002,
          'results': [
            {
              'schemaVersion': 1,
              'commandId': command1,
              'cameraId': _camera1,
              'status': 'restored',
              'code': 'restored',
              'readback': _commandReadback(
                command1,
                _scope1(),
                8,
                _modeAway(),
                1002,
              ),
            },
            {
              'schemaVersion': 1,
              'commandId': command2,
              'cameraId': _camera2,
              'status': 'skipped',
              'code': 'not_changed',
              'readback': null,
            },
          ],
        },
      });
    }
    return _error(request, 404);
  }

  Future<void> close() => server.close(force: true);
}

Map<String, dynamic> _scope1() => {
  'schemaVersion': 1,
  'cameraId': _camera1,
  'cameraRevision': 2,
  'areaId': _area1,
  'areaRevision': 3,
  'serviceId': _service1,
  'serviceRevision': 4,
  'bindingId': _binding1,
  'bindingRevision': 5,
};

Map<String, dynamic> _scope2() => {
  'schemaVersion': 1,
  'cameraId': _camera2,
  'cameraRevision': 12,
  'areaId': _area2,
  'areaRevision': 13,
  'serviceId': _service2,
  'serviceRevision': 14,
  'bindingId': _binding2,
  'bindingRevision': 15,
};

Map<String, dynamic> _modeAway() => {
  'recording': 'enabled',
  'detection': 'enabled',
};
Map<String, dynamic> _modeHome() => {
  'recording': 'paused',
  'detection': 'disabled',
};

Map<String, dynamic> _authority() => {
  'schemaVersion': 1,
  'coreId': _core,
  'homeId': _home,
  'homeRevision': 1,
  'accountId': _accountId,
  'accountRevision': 2,
  'sessionFamilyId': _family,
  'role': 'admin',
  'active': true,
  'canManageCameraProfiles': true,
};

Map<String, dynamic> _commandReadback(
  String commandId,
  Map<String, dynamic> scope,
  int revision,
  Map<String, dynamic> mode,
  int observedAt,
) => {
  'schemaVersion': 1,
  'commandId': commandId,
  'camera': scope,
  'stateRevision': revision,
  'mode': mode,
  'observedAtMs': observedAt,
};

Map<String, dynamic> _snapshot() {
  final scopes = [_scope1(), _scope2()];
  return {
    'schemaVersion': 1,
    'authority': _authority(),
    'policy': {
      'schemaVersion': 1,
      'coreId': _core,
      'homeId': _home,
      'profileId': _profile,
      'profileRevision': 3,
      'presenceSourceId': _source,
      'presenceSourceRevision': 4,
      'cameras': scopes,
      'enterDelayMs': 0,
      'exitDelayMs': 0,
      'hysteresisMs': 0,
      'presenceMaxAgeMs': 60000,
      'atHomeMode': _modeHome(),
      'awayMode': _modeAway(),
      'failSafeMode': _modeAway(),
      'active': true,
    },
    'signal': {
      'schemaVersion': 1,
      'coreId': _core,
      'homeId': _home,
      'sourceId': _source,
      'sourceRevision': 4,
      'signalRevision': 5,
      'observedAtMs': 1000,
      'state': 'home',
    },
    'decision': {
      'schemaVersion': 1,
      'coreId': _core,
      'homeId': _home,
      'homeRevision': 1,
      'profileId': _profile,
      'profileRevision': 3,
      'policyHash': 'f' * 64,
      'actorAccountId': _accountId,
      'accountRevision': 2,
      'sessionFamilyId': _family,
      'presenceSourceId': _source,
      'presenceSourceRevision': 4,
      'signalRevision': 5,
      'evaluatedAtMs': 1000,
      'reason': 'presence_home',
      'mode': _modeHome(),
      'targets': [
        for (final scope in scopes)
          {'schemaVersion': 1, 'camera': scope, 'mode': _modeHome()},
      ],
    },
    'readbacks': [
      for (var index = 0; index < scopes.length; index++)
        {
          'schemaVersion': 1,
          'coreId': _core,
          'homeId': _home,
          'camera': scopes[index],
          'stateRevision': index == 0 ? 6 : 16,
          'mode': _modeAway(),
          'observedAtMs': 1000,
        },
    ],
    'support': [
      for (var index = 0; index < scopes.length; index++)
        {
          'schemaVersion': 1,
          'camera': scopes[index],
          'displayName': index == 0 ? 'Front door' : 'Back door',
          'providerRevision': index == 0 ? 7 : 17,
          'recordingSupported': true,
          'detectionSupported': true,
          'verifiedAtMs': 1000,
        },
    ],
    'privacyBoundary': {
      'microphoneDisabled': false,
      'cameraHardwareDisabled': false,
      'otherRecordersDisabled': false,
    },
  };
}

void _json(HttpRequest request, Object value, [int status = 200]) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(value));
  unawaited(request.response.close());
}

void _error(HttpRequest request, int status) => _json(request, {
  'error': {'code': 'invalid_request'},
}, status);

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('production client preserves partial lost-ACK receipt and verifies rollback readback over loopback', () async {
    final core = await _ProfileCore.start();
    addTearDown(core.close);
    final account = ServerAccountController(
      store: _Store(),
      apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
    );
    addTearDown(account.dispose);
    await account.signIn(
      baseUrl: core.baseUrl,
      username: 'admin',
      password: 'synthetic-password',
      deviceName: 'test-tablet',
    );
    expect(account.session, isNotNull);
    final api = CoreCameraProfileApi(
      account: account,
      routeId: 'abababababababababababababababab',
      sessionRevision: 1,
      routeRevision: 2,
      isCurrent: () => true,
      random: Random(41),
    );

    final snapshot = await api.bootstrap();
    expect(snapshot.cameras, hasLength(2));
    final receipt = await api.apply(snapshot);
    expect(receipt.status, 'partial');
    expect(receipt.results.first.state, CameraApplyState.applied);
    expect(receipt.results.first.readbackStateRevision, 7);
    expect(receipt.results.last.state, CameraApplyState.unknown);
    expect(receipt.results.last.code, 'worker_ack_unknown');
    expect(receipt.canRollback, isTrue);
    expect(core.applyCalls, 1, reason: 'lost ACK must not trigger a replay');

    final rollback = await api.rollback(snapshot, receipt);
    expect(rollback.status, 'restored');
    expect(rollback.fullyRestored, isTrue);
    expect(rollback.originalRequestId, receipt.requestId);
    expect(rollback.results.first.state, CameraRollbackState.restored);
    expect(rollback.results.last.state, CameraRollbackState.skipped);
    expect(core.rollbackOriginalRequestId, receipt.requestId);
    expect(core.loginCalls, 1);
    expect(core.snapshotCalls, 1);
    expect(core.applyCalls, 1);
    expect(core.rollbackCalls, 1);
  });
}
