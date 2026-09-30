import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy_priorities/data/core_energy_priority_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _accountId = '33333333333333333333333333333333';
const _family = '44444444444444444444444444444444';
const _meter = '55555555555555555555555555555555';
const _forecast = '66666666666666666666666666666666';
const _tariff = '77777777777777777777777777777777';
const _battery = '88888888888888888888888888888888';
const _inverter = '99999999999999999999999999999999';
const _plan = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _digest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _confirmation =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _access = 'energy_priority_loopback_access_token_12345';
const _refresh = 'energy_priority_loopback_refresh_token_1234';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _EnergyCore {
  _EnergyCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  String? requestId;
  int loads = 0, previews = 0, confirms = 0, readbacks = 0, effects = 0;
  Completer<void>? previewEntered, previewBarrier;

  String get baseUrl => 'http://127.0.0.1:${server.port}';
  static Future<_EnergyCore> start() async =>
      _EnergyCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

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
    if (request.method == 'GET' && path == '/api/v1/context') {
      return _json(request, {
        'schemaVersion': 1,
        'coreId': _core,
        'homeId': _home,
      });
    }
    final root = '/api/v1/energy-priorities/$_core/$_home';
    if (request.method == 'GET' && path == root) {
      loads++;
      return _json(request, _snapshot());
    }
    if (request.method == 'POST' && path == '$root/previews') {
      previews++;
      final body = await _body(request);
      requestId = body['requestId'] as String?;
      if (body['planId'] != _plan ||
          body['inputDigest'] != _digest ||
          body['slotIndex'] != 0 ||
          body['inverterId'] != _inverter ||
          body['expectedInverterRevision'] != 11 ||
          body['expectedAccountRevision'] != 2 ||
          body['expectedHomeRevision'] != 1) {
        return _error(request, 409);
      }
      previewEntered?.complete();
      await previewBarrier?.future;
      return _json(request, _preview(requestId!));
    }
    if (request.method == 'POST' &&
        path == '$root/previews/$requestId/confirm') {
      confirms++;
      final body = await _body(request);
      if (body['confirmationToken'] != _confirmation) {
        return _error(request, 409);
      }
      effects++;
      return _json(request, _result(requestId!, verified: false));
    }
    if (request.method == 'GET' && path == '$root/commands/$requestId') {
      readbacks++;
      return _json(request, _result(requestId!, verified: true));
    }
    return _error(request, 404);
  }

  Map<String, dynamic> _snapshot() => {
    'schemaVersion': 1,
    'authority': {
      'schemaVersion': 1,
      'coreId': _core,
      'homeId': _home,
      'homeRevision': 1,
      'accountId': _accountId,
      'accountRevision': 2,
      'memberRevision': 2,
      'sessionFamilyId': _family,
      'role': 'admin',
      'active': true,
      'canPlan': true,
      'canControl': true,
    },
    'inputs': {
      'schemaVersion': 1,
      'coreId': _core,
      'homeId': _home,
      'homeRevision': 1,
      'meter': {
        'schemaVersion': 1,
        'resourceId': _meter,
        'revision': 3,
        'providerRevision': 4,
        'capturedAtMs': 1000,
        'gridImportPowerW': 0,
        'gridExportPowerW': 0,
      },
      'forecast': {
        'schemaVersion': 1,
        'resourceId': _forecast,
        'revision': 5,
        'providerRevision': 6,
        'generatedAtMs': 1000,
        'startsAtMs': 1000,
        'slotDurationSeconds': 3600,
        'solarEnergyWh': [3000],
        'loadEnergyWh': [1000],
      },
      'tariff': {
        'schemaVersion': 1,
        'resourceId': _tariff,
        'revision': 7,
        'startsAtMs': 1000,
        'slotDurationSeconds': 3600,
        'importPriceMicrosPerKwh': [100000],
        'exportPriceMicrosPerKwh': [50000],
      },
      'battery': {
        'schemaVersion': 1,
        'resourceId': _battery,
        'revision': 8,
        'providerRevision': 9,
        'capturedAtMs': 1000,
        'capacityWh': 10000,
        'stateOfChargeWh': 5000,
        'minimumSocWh': 4000,
        'maximumSocWh': 9000,
        'maxChargePowerW': 2000,
        'maxDischargePowerW': 1000,
      },
      'reserve': {
        'schemaVersion': 1,
        'revision': 10,
        'backupReservePercent': 40,
      },
      'manualOverride': null,
    },
    'plan': {
      'schemaVersion': 1,
      'planId': _plan,
      'coreId': _core,
      'homeId': _home,
      'homeRevision': 1,
      'batteryId': _battery,
      'batteryRevision': 8,
      'batteryProviderRevision': 9,
      'meterRevision': 3,
      'forecastRevision': 5,
      'forecastProviderRevision': 6,
      'tariffRevision': 7,
      'reserveRevision': 10,
      'overrideRevision': null,
      'inputDigest': _digest,
      'advisory': true,
      'automaticExecutionAllowed': false,
      'overrideStatus': 'none',
      'overrideExpiresAtMs': null,
      'slots': [
        {
          'schemaVersion': 1,
          'index': 0,
          'startsAtMs': 1000,
          'action': 'charge',
          'powerW': 2000,
          'projectedSocWh': 7000,
          'reason': 'solar_surplus',
        },
      ],
    },
    'inverter': {
      'schemaVersion': 1,
      'inverterId': _inverter,
      'revision': 11,
      'canCharge': true,
      'canDischarge': true,
      'writable': true,
      'physicalAcceptance': 'manual',
    },
  };

  Map<String, dynamic> _preview(String id) => {
    'schemaVersion': 1,
    'requestId': id,
    'planId': _plan,
    'coreId': _core,
    'homeId': _home,
    'accountId': _accountId,
    'accountRevision': 2,
    'memberRevision': 2,
    'sessionFamilyId': _family,
    'inverterId': _inverter,
    'expectedInverterRevision': 11,
    'batteryId': _battery,
    'expectedBatteryRevision': 8,
    'inputDigest': _digest,
    'targetPowerW': 2000,
    'expiresAtMs': 100000,
    'confirmationToken': _confirmation,
  };

  Map<String, dynamic> _result(String id, {required bool verified}) => {
    'schemaVersion': 1,
    'requestId': id,
    'status': verified ? 'confirmed' : 'awaiting_readback',
    'reason': verified ? null : 'worker_ack_unknown',
    'readbackVerified': verified,
    'readback': verified
        ? {
            'schemaVersion': 1,
            'requestId': id,
            'coreId': _core,
            'homeId': _home,
            'inverterId': _inverter,
            'inverterRevision': 11,
            'batteryId': _battery,
            'batteryRevision': 8,
            'inputDigest': _digest,
            'targetPowerW': 2000,
            'observedPowerW': 2000,
            'status': 'applied',
          }
        : null,
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

Future<ServerAccountController> _signIn(_EnergyCore core) async {
  final account = ServerAccountController(
    store: _Store(),
    apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
  );
  await account.signIn(
    baseUrl: core.baseUrl,
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'test-tablet',
  );
  return account;
}

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('production client keeps solar plan advisory and confirms only after exact inverter readback', () async {
    final core = await _EnergyCore.start();
    addTearDown(core.close);
    final account = await _signIn(core);
    addTearDown(account.dispose);
    final api = CoreEnergyPriorityApi(
      account: account,
      isCurrent: () => true,
      random: Random(47),
    );

    final snapshot = await api.load();
    expect(snapshot.reservePercent, 40);
    expect(snapshot.stateOfChargePercent, 50);
    expect(snapshot.solarEnergyWh, 3000);
    expect(snapshot.consumptionEnergyWh, 1000);
    final preview = await api.preview(snapshot, snapshot.slots.single);
    expect(preview.targetPowerW, 2000);

    final uncertain = await api.confirm(preview);
    expect(uncertain.verified, isFalse);
    expect(core.confirms, 1, reason: 'lost ACK is not automatically replayed');
    expect(core.effects, 1);

    final readback = await api.readback(preview);
    expect(readback.exactFor(preview), isTrue);
    expect(core.previews, 1);
    expect(core.confirms, 1);
    expect(core.readbacks, 1);
    expect(core.effects, 1);
  });

  test(
    'late inverter preview is discarded after authority retirement',
    () async {
      final core = await _EnergyCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      var current = true;
      core.previewEntered = Completer<void>();
      core.previewBarrier = Completer<void>();
      final api = CoreEnergyPriorityApi(
        account: account,
        isCurrent: () => current,
      );
      final snapshot = await api.load();
      final pending = api.preview(snapshot, snapshot.slots.single);
      await core.previewEntered!.future;
      current = false;
      core.previewBarrier!.complete();
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
      expect(api.boundSession, isNull);
    },
  );
}
