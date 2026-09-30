import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_comfort/data/room_comfort_api.dart';
import 'package:larenor/features/room_comfort/domain/room_comfort_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _account = '33333333333333333333333333333333';
const _family = '44444444444444444444444444444444';
const _policy = '55555555555555555555555555555555';
const _plan = '66666666666666666666666666666666';
const _heatRoom = '77777777777777777777777777777777';
const _airRoom = '88888888888888888888888888888888';
const _preview = '99999999999999999999999999999999';
const _request = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _access = 'room_comfort_loopback_access_token_123456789';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _ComfortCore {
  _ComfortCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  int loads = 0, previews = 0, confirms = 0;
  Completer<void>? entered, barrier;
  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_ComfortCore> start() async =>
      _ComfortCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'POST' && path == '/api/v1/auth/login') {
      await _body(request);
      return _json(request, {
        'accessToken': _access,
        'refreshToken': 'room_comfort_loopback_refresh_token_12345678',
        'expiresIn': 3600,
        'sessionFamilyId': _family,
        'user': {
          'id': _account,
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
    if (request.method == 'GET' && path == '/api/v1/context') {
      return _json(request, {
        'schemaVersion': 1,
        'coreId': _core,
        'homeId': _home,
      });
    }
    final root = '/api/v1/room-comfort/$_core/$_home';
    if (request.method == 'GET' && path == '$root/plan') {
      loads++;
      entered?.complete();
      await barrier?.future;
      return _json(request, {'schemaVersion': 1, 'plan': _planBody()});
    }
    if (request.method == 'POST' && path == '$root/previews') {
      previews++;
      final body = await _body(request);
      if (body['requestId'] != _request ||
          body['expectedPlanId'] != _plan ||
          body['expectedHomeRevision'] != 2 ||
          body['expectedPolicyRevision'] != 4) {
        return _error(request, 409);
      }
      return _json(request, {
        'schemaVersion': 1,
        'preview': {
          'schemaVersion': 1,
          'previewId': _preview,
          'confirmToken': 'T' * 43,
          'requestId': _request,
          'planId': _plan,
          'expiresAtMs': 2000000,
          'commandCount': 2,
        },
      }, 201);
    }
    if (request.method == 'POST' &&
        path == '$root/previews/$_preview/confirm') {
      confirms++;
      final body = await _body(request);
      if (body['expectedPlanId'] != _plan ||
          body['expectedPolicyRevision'] != 4 ||
          body['confirmToken'] != 'T' * 43) {
        return _error(request, 409);
      }
      return _json(request, {'schemaVersion': 1, 'receipt': _receipt()}, 201);
    }
    return _error(request, 404);
  }

  Map<String, dynamic> _planBody() => {
    'schemaVersion': 1,
    'planId': _plan,
    'coreId': _core,
    'homeId': _home,
    'homeRevision': 2,
    'policyId': _policy,
    'policyRevision': 4,
    'policyHash': 'f' * 64,
    'actorAccountId': _account,
    'accountRevision': 3,
    'sessionFamilyId': _family,
    'generatedAtMs': 1020000,
    'inputRevisions': {
      'temperature': 10,
      'humidity': 11,
      'co2': 12,
      'window': 13,
      'hvac': 14,
    },
    'occupancyAdvisory': {_heatRoom: 'occupied', _airRoom: 'occupied'},
    'items': [
      _item(
        roomId: _heatRoom,
        areaId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        reason: 'temperature_low',
        hvacMode: 'heat',
        windowState: 'closed',
      ),
      _item(
        roomId: _airRoom,
        areaId: 'cccccccccccccccccccccccccccccccc',
        reason: 'air_refresh',
        hvacMode: 'ventilate',
        windowState: 'open',
      ),
    ],
  };

  Map<String, dynamic> _item({
    required String roomId,
    required String areaId,
    required String reason,
    required String hvacMode,
    required String windowState,
  }) => {
    'schemaVersion': 1,
    'room': {
      'schemaVersion': 1,
      'coreId': _core,
      'homeId': _home,
      'roomId': roomId,
      'roomRevision': 5,
      'areaId': areaId,
      'areaRevision': 6,
      'hvac': {'serviceRevision': 7},
      'window': {'serviceRevision': 8},
    },
    'status': 'planned',
    'reason': reason,
    'hvacMode': hvacMode,
    'windowState': windowState,
  };

  Map<String, dynamic> _receipt() => {
    'schemaVersion': 1,
    'requestId': _request,
    'planId': _plan,
    'status': 'applied',
    'results': [
      _result(
        commandId: 'dddddddddddddddddddddddddddddddd',
        roomId: _heatRoom,
        kind: 'hvac',
        readback: {'mode': 'heat', 'temperatureMilliC': 20500},
      ),
      _result(
        commandId: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        roomId: _airRoom,
        kind: 'window',
        readback: {'state': 'open', 'co2Ppm': 1100},
      ),
    ],
    'completedAtMs': 1021000,
  };

  Map<String, dynamic> _result({
    required String commandId,
    required String roomId,
    required String kind,
    required Map<String, Object?> readback,
  }) => {
    'schemaVersion': 1,
    'commandId': commandId,
    'roomId': roomId,
    'targetKind': kind,
    'status': 'applied',
    'code': 'applied',
    'readback': readback,
  };

  Future<void> close() => server.close(force: true);
}

void _json(HttpRequest request, Object body, [int status = 200]) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  unawaited(request.response.close());
}

void _error(HttpRequest request, int status) => _json(request, {
  'error': {'code': 'conflict'},
}, status);

Future<ServerAccountController> _signIn(_ComfortCore core) async {
  final account = ServerAccountController(
    store: _Store(),
    apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
  );
  await account.signIn(
    baseUrl: core.baseUrl,
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'tablet',
  );
  return account;
}

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('production client verifies HVAC and window readback receipt', () async {
    final core = await _ComfortCore.start();
    addTearDown(core.close);
    final account = await _signIn(core);
    addTearDown(account.dispose);
    final api = AccountRoomComfortGateway(
      account: account,
      isCurrent: () => true,
    );
    final plan = await api.loadPlan();
    expect(plan.rooms, hasLength(2));
    expect(plan.rooms.first.reason, ComfortReason.temperatureLow);
    expect(plan.rooms.last.reason, ComfortReason.airRefresh);
    expect(plan.rooms.last.windowState, ComfortWindowState.open);
    final preview = await api.preview(plan, _request);
    expect(preview.commandCount, 2);
    final receipt = await api.confirm(preview);
    expect(receipt.status, 'applied');
    expect(receipt.appliedCount, 2);
    expect((core.loads, core.previews, core.confirms), (1, 1, 1));
  });

  test('late comfort plan is cancelled after authority changes', () async {
    final core = await _ComfortCore.start();
    addTearDown(core.close);
    final account = await _signIn(core);
    addTearDown(account.dispose);
    var current = true;
    core.entered = Completer<void>();
    core.barrier = Completer<void>();
    final api = AccountRoomComfortGateway(
      account: account,
      isCurrent: () => current,
    );
    final pending = api.loadPlan();
    await core.entered!.future;
    current = false;
    core.barrier!.complete();
    await expectLater(
      pending,
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
  });
}
