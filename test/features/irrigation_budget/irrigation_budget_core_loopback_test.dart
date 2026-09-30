import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/irrigation_budget/data/irrigation_budget_api.dart';
import 'package:larenor/features/irrigation_budget/data/irrigation_source_api.dart';
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
const _zone = '77777777777777777777777777777777';
const _preview = '88888888888888888888888888888888';
const _command = '99999999999999999999999999999999';
const _service = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _room = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _access = 'irrigation_loopback_access_token_123456789';
const _confirmToken = 'T123456789012345678901234567890123456789012';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _IrrigationCore {
  _IrrigationCore._(this.server) {
    unawaited(_serve());
  }
  final HttpServer server;
  int loads = 0, previews = 0, confirms = 0, stops = 0;
  Completer<void>? entered, barrier;
  String get baseUrl => 'http://127.0.0.1:${server.port}';
  static Future<_IrrigationCore> start() async =>
      _IrrigationCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
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
        'refreshToken': 'irrigation_loopback_refresh_token_12345678',
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
    if (request.method == 'GET' && path == '/api/v1/admin/services') {
      return _json(request, {
        'services': [
          {
            'id': _service,
            'name': 'Garden Home Assistant',
            'kind': 'home_assistant',
            'baseUrl': 'http://home-assistant.fixture.invalid',
            'revision': 2,
            'credentialKeys': ['token'],
            'verification': {
              'state': 'authenticated',
              'checkedAt': '2026-09-30T10:00:00Z',
              'version': '2026.9.0',
            },
          },
        ],
      });
    }
    if (request.method == 'GET' &&
        path == '/api/v1/home-resources/$_core/$_home') {
      return _json(request, {
        'scope': {'schemaVersion': 1, 'coreId': _core, 'homeId': _home},
        'userRevision': 4,
        'entries': [
          {
            'ref': {
              'schemaVersion': 1,
              'coreId': _core,
              'homeId': _home,
              'kind': 'room',
              'id': _room,
            },
            'revision': 5,
            'aclRevision': 6,
            'permissions': {'read': true, 'write': true},
            'label': 'Back garden',
            'order': 1,
          },
        ],
        'snapshot':
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        'nextAfter': null,
      });
    }
    if (request.method == 'GET' &&
        (path == '/api/v1/admin/irrigation-budget/source' ||
            path == '/api/v1/admin/irrigation-budget/controller')) {
      return _error(request, 409);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/irrigation-budget') {
      loads++;
      entered?.complete();
      await barrier?.future;
      return _json(request, {'snapshot': _snapshot()});
    }
    if (request.method == 'POST' && path.endsWith('/preview')) {
      previews++;
      final body = await _body(request);
      return _json(request, {
        'schemaVersion': 1,
        'preview': {
          'schemaVersion': 1,
          'previewId': _preview,
          'confirmToken': _confirmToken,
          'requestId': body['requestId'],
          'planId': _plan,
          'policyRevision': 4,
          'expiresAtMs': 2000000,
          'commandCount': 1,
        },
      });
    }
    if (request.method == 'POST' && path.endsWith('/confirm')) {
      confirms++;
      final body = await _body(request);
      if (body['previewId'] != _preview ||
          body['confirmToken'] != _confirmToken) {
        return _error(request, 409);
      }
      return _json(request, _receipt(stop: false));
    }
    if (request.method == 'POST' && path.endsWith('/stop')) {
      stops++;
      final body = await _body(request);
      if ((body['zoneIds'] as List).single != _zone) {
        return _error(request, 409);
      }
      return _json(
        request,
        _receipt(stop: true, requestId: body['requestId'] as String),
      );
    }
    return _error(request, 404);
  }

  Map<String, dynamic> _snapshot() => {
    'schemaVersion': 1,
    'authority': {
      'schemaVersion': 1,
      'coreId': _core,
      'homeId': _home,
      'homeRevision': 2,
      'accountId': _account,
      'accountRevision': 3,
      'sessionFamilyId': _family,
      'role': 'admin',
      'active': true,
      'canManageIrrigation': true,
    },
    'policyId': _policy,
    'policyRevision': 4,
    'planId': _plan,
    'generatedAtMs': 1020000,
    'forecastStatus': 'available',
    'rainMilliMm': 1250,
    'budget': {
      'revision': 5,
      'dailyLimitMl': 100000,
      'usedMl': 12000,
      'plannedMl': 18000,
      'estimatedCostMicros': 360000,
    },
    'zones': [
      {
        'zoneId': _zone,
        'zoneRevision': 6,
        'areaName': 'Back garden',
        'plantName': 'Tomatoes',
        'moisturePermille': 300,
        'soilReadingRevision': 7,
        'status': 'planned',
        'reason': 'moisture_deficit',
        'durationSeconds': 600,
        'estimatedWaterMl': 18000,
      },
    ],
    'controlCapability': 'verified_control',
    'commandEndpointAvailable': true,
  };

  Map<String, dynamic> _receipt({required bool stop, String? requestId}) => {
    'schemaVersion': 1,
    'receipt': {
      'schemaVersion': 1,
      'requestId': requestId ?? _command,
      if (!stop) 'planId': _plan,
      'status': stop ? 'stopped' : 'applied',
      'results': [
        {
          'schemaVersion': 1,
          'commandId': _command,
          'zoneId': _zone,
          'status': stop ? 'stopped' : 'applied',
          'code': stop ? 'stopped' : 'applied',
          'readback': {
            'schemaVersion': 1,
            'commandId': _command,
            'zone': _zoneScope(),
            'stateRevision': stop ? 9 : 8,
            'valveOpen': false,
            if (stop) 'flowActive': false else 'deliveredMl': 18000,
            if (!stop) 'flowVerified': true,
            'observedAtMs': 1021000,
          },
        },
      ],
      'completedAtMs': 1021000,
    },
  };

  Map<String, dynamic> _zoneScope() => {
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
    'zoneId': _zone,
    'zoneRevision': 6,
    'areaId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'areaRevision': 1,
    'valveServiceId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    'valveServiceRevision': 2,
    'valveBindingId': 'cccccccccccccccccccccccccccccccc',
    'valveBindingRevision': 3,
    'flowMlPerMinute': 1800,
    'maxDurationSeconds': 7200,
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
Future<ServerAccountController> _signIn(_IrrigationCore core) async {
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
  test(
    'production client verifies budget, flow readback, and safe stop',
    () async {
      final core = await _IrrigationCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      final api = CoreIrrigationBudgetApi(
        account: account,
        routeId: 'irrigation-route',
        sessionRevision: 1,
        routeRevision: 2,
        isCurrent: () => true,
      );
      final snapshot = await api.load();
      expect(
        snapshot.plannedMl + snapshot.usedMl,
        lessThanOrEqualTo(snapshot.dailyLimitMl),
      );
      expect(snapshot.zones.single.reason, 'moisture_deficit');
      final preview = await api.preview(snapshot);
      final receipt = await api.confirm(preview);
      expect(receipt.status, 'applied');
      expect(receipt.results.single.code, 'applied');
      expect(receipt.results.single.flowVerified, isTrue);
      expect(receipt.results.single.deliveredMl, 18000);
      expect(receipt.results.single.flowActive, isNull);
      final stopped = await api.stop(snapshot, const [_zone]);
      expect(stopped.status, 'stopped');
      expect(stopped.results.single.code, 'stopped');
      expect(stopped.results.single.flowActive, isFalse);
      expect(stopped.results.single.flowVerified, isNull);
      expect(stopped.results.single.deliveredMl, isNull);
      expect(
        (core.loads, core.previews, core.confirms, core.stops),
        (1, 1, 1, 1),
      );
    },
  );

  test(
    'production source setup lists exact current HA and room bindings',
    () async {
      final core = await _IrrigationCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      final api = CoreIrrigationSourceApi(
        account: account,
        isCurrent: () => true,
      );
      addTearDown(api.retire);

      final catalog = await api.load();
      expect(catalog.services.single.id, _service);
      expect(catalog.services.single.revision, 2);
      expect(catalog.rooms.single.id, _room);
      expect(catalog.rooms.single.revision, 5);
      expect(catalog.source, isNull);
      expect(catalog.controller, isNull);
    },
  );

  test(
    'late irrigation snapshot is cancelled after authority changes',
    () async {
      final core = await _IrrigationCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      var current = true;
      core.entered = Completer<void>();
      core.barrier = Completer<void>();
      final api = CoreIrrigationBudgetApi(
        account: account,
        routeId: 'irrigation-route',
        sessionRevision: 1,
        routeRevision: 2,
        isCurrent: () => current,
      );
      final pending = api.load();
      await core.entered!.future;
      current = false;
      core.barrier!.complete();
      await expectLater(pending, throwsA(isA<LarenorServerException>()));
    },
  );
}
