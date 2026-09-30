import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/power_budget/data/power_budget_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _account = '33333333333333333333333333333333';
const _access = 'power_budget_loopback_access_token_1234567';
const _plan = 'power-plan';
const _hash =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _PowerCore {
  _PowerCore._(this.server) {
    unawaited(_serve());
  }
  final HttpServer server;
  int loads = 0, confirms = 0;
  Completer<void>? entered, barrier;
  String get baseUrl => 'http://127.0.0.1:${server.port}';
  static Future<_PowerCore> start() async =>
      _PowerCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
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
        'refreshToken': 'power_budget_loopback_refresh_token_123456',
        'expiresIn': 3600,
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
    if (request.method == 'GET' && path == '/api/v1/admin/power-budget') {
      loads++;
      entered?.complete();
      await barrier?.future;
      return _json(request, {'snapshot': _snapshot()});
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/power-budget/confirm') {
      confirms++;
      final body = await _body(request);
      if (body['previewId'] != _plan ||
          body['expectedPlanHash'] != _hash ||
          !(body['requestKey'] as String).startsWith('power-budget:')) {
        return _error(request, 409);
      }
      return _json(request, {
        'receipt': {
          'schemaVersion': 1,
          'commandId': 'command-1',
          'previewId': _plan,
          'planHash': _hash,
          'status': 'verified',
          'applyCount': 1,
          'communicationLossBehavior': {'ev-charger': 'stop_charging'},
        },
      });
    }
    return _error(request, 404);
  }

  Map<String, dynamic> _snapshot() => {
    'schemaVersion': 1,
    'authority': {
      'coreId': _core,
      'homeId': _home,
      'accountId': _account,
      'sessionId': 'session-1',
      'coreRevision': 1,
      'homeRevision': 2,
      'accountRevision': 3,
      'meterId': 'meter-1',
      'meterRevision': 4,
      'tariffRevision': 5,
      'loadRegistryRevision': 6,
      'gridLimitRevision': 7,
      'overrideRevision': 8,
      'planRevision': 9,
      'canControl': true,
    },
    'measurement': {
      'gridImportW': 11500,
      'gridLimitW': 8000,
      'tariffMicrosPerKwh': 1250000,
      'providerStatus': {'meter': 'verified', 'tariff': 'verified'},
    },
    'plan': {
      'id': _plan,
      'status': 'ready',
      'planHash': _hash,
      'planRevision': 9,
      'requiredReductionW': 3500,
      'overrideExpiresAtMs': null,
      'actions': [
        {
          'loadId': 'ev-charger',
          'label': 'EV charger',
          'loadRevision': 1,
          'reductionW': 3500,
          'targetW': 0,
          'priority': 10,
          'communicationLossBehavior': 'stop_charging',
        },
      ],
    },
    'controlCapability': 'manual_required',
    'commandEndpointAvailable': true,
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

Future<ServerAccountController> _signIn(_PowerCore core) async {
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
    'production client verifies power plan and communication-loss receipt',
    () async {
      final core = await _PowerCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      final api = CorePowerBudgetApi(
        account: account,
        routeId: 'power-route',
        sessionRevision: 1,
        routeRevision: 2,
        isCurrent: () => true,
      );
      final snapshot = await api.load();
      expect(snapshot.meterStatus, 'verified');
      expect(snapshot.tariffStatus, 'verified');
      expect(snapshot.requiredReductionW, 3500);
      expect(
        snapshot.actions.single.communicationLossBehavior,
        'stop_charging',
      );
      final receipt = await api.confirm(snapshot);
      expect(receipt.status, 'verified');
      expect(receipt.applyCount, 1);
      expect(core.loads, 1);
      expect(core.confirms, 1);
    },
  );

  test(
    'late meter snapshot is discarded after route authority changes',
    () async {
      final core = await _PowerCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      var current = true;
      core.entered = Completer<void>();
      core.barrier = Completer<void>();
      final api = CorePowerBudgetApi(
        account: account,
        routeId: 'power-route',
        sessionRevision: 1,
        routeRevision: 2,
        isCurrent: () => current,
      );
      final pending = api.load();
      await core.entered!.future;
      current = false;
      core.barrier!.complete();
      await expectLater(
        pending,
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
  );
}
