import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/energy_priorities/data/core_energy_priority_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const accountId = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';
const meter = '55555555555555555555555555555555';
const forecast = '66666666666666666666666666666666';
const tariff = '77777777777777777777777777777777';
const battery = '88888888888888888888888888888888';
const inverter = '99999999999999999999999999999999';
const planId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
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

Future<ServerAccountController> _account(
  Future<http.Response> Function(http.Request) handler,
) async {
  final value = ServerAccountController(
    store: _Store(),
    apiFactory: (endpoint) =>
        LarenorServerApi(endpoint: endpoint, client: MockClient(handler)),
  );
  await value.signIn(
    baseUrl: 'https://core.invalid',
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'tablet',
  );
  return value;
}

Future<http.Response> _session(http.Request request) async {
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
  throw StateError('unexpected session route');
}

Map<String, Object?> _snapshot({String sessionFamilyId = family}) => {
  'schemaVersion': 1,
  'authority': {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
    'homeRevision': 1,
    'accountId': accountId,
    'accountRevision': 2,
    'memberRevision': 2,
    'sessionFamilyId': sessionFamilyId,
    'role': 'admin',
    'active': true,
    'canPlan': true,
    'canControl': true,
  },
  'inputs': {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
    'homeRevision': 1,
    'meter': {
      'schemaVersion': 1,
      'resourceId': meter,
      'revision': 3,
      'providerRevision': 4,
      'capturedAtMs': 1000,
      'gridImportPowerW': 0,
      'gridExportPowerW': 0,
    },
    'forecast': {
      'schemaVersion': 1,
      'resourceId': forecast,
      'revision': 5,
      'providerRevision': 6,
      'generatedAtMs': 1000,
      'startsAtMs': 1000,
      'slotDurationSeconds': 3600,
      'solarEnergyWh': [3000, 0],
      'loadEnergyWh': [1000, 2000],
    },
    'tariff': {
      'schemaVersion': 1,
      'resourceId': tariff,
      'revision': 7,
      'startsAtMs': 1000,
      'slotDurationSeconds': 3600,
      'importPriceMicrosPerKwh': [100000, 400000],
      'exportPriceMicrosPerKwh': [50000, 50000],
    },
    'battery': {
      'schemaVersion': 1,
      'resourceId': battery,
      'revision': 8,
      'providerRevision': 9,
      'capturedAtMs': 1000,
      'capacityWh': 10000,
      'stateOfChargeWh': 5000,
      'minimumSocWh': 1000,
      'maximumSocWh': 9000,
      'maxChargePowerW': 2000,
      'maxDischargePowerW': 1000,
    },
    'reserve': {'schemaVersion': 1, 'revision': 10, 'backupReservePercent': 40},
    'manualOverride': null,
  },
  'plan': {
    'schemaVersion': 1,
    'planId': planId,
    'coreId': core,
    'homeId': home,
    'homeRevision': 1,
    'batteryId': battery,
    'batteryRevision': 8,
    'batteryProviderRevision': 9,
    'meterRevision': 3,
    'forecastRevision': 5,
    'forecastProviderRevision': 6,
    'tariffRevision': 7,
    'reserveRevision': 10,
    'overrideRevision': null,
    'inputDigest': digest,
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
      {
        'schemaVersion': 1,
        'index': 1,
        'startsAtMs': 3601000,
        'action': 'discharge',
        'powerW': 1000,
        'projectedSocWh': 6000,
        'reason': 'high_tariff_deficit',
      },
    ],
  },
  'inverter': {
    'schemaVersion': 1,
    'inverterId': inverter,
    'revision': 11,
    'canCharge': true,
    'canDischarge': true,
    'writable': true,
    'physicalAcceptance': 'manual',
  },
};

Map<String, Object?> _result(String requestId) => {
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
    'inverterId': inverter,
    'inverterRevision': 11,
    'batteryId': battery,
    'batteryRevision': 8,
    'inputDigest': digest,
    'targetPowerW': 2000,
    'observedPowerW': 2000,
    'status': 'applied',
  },
};

void main() {
  test(
    'HTTP adapter verifies preview confirm and authenticated readback',
    () async {
      var requestId = '';
      final requests = <http.Request>[];
      final account = await _account((request) async {
        if (request.url.path.endsWith('/auth/login') ||
            request.url.path.endsWith('/context')) {
          return _session(request);
        }
        requests.add(request);
        if (request.method == 'GET' &&
            !request.url.path.contains('/commands/')) {
          return _json(_snapshot());
        }
        if (request.url.path.endsWith('/previews')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requestId = body['requestId'] as String;
          return _json({
            'schemaVersion': 1,
            'requestId': requestId,
            'planId': planId,
            'coreId': core,
            'homeId': home,
            'accountId': accountId,
            'accountRevision': 2,
            'memberRevision': 2,
            'sessionFamilyId': family,
            'inverterId': inverter,
            'expectedInverterRevision': 11,
            'batteryId': battery,
            'expectedBatteryRevision': 8,
            'inputDigest': digest,
            'targetPowerW': 2000,
            'expiresAtMs': 100000,
            'confirmationToken': 'c' * 64,
          }, 201);
        }
        return _json(_result(requestId));
      });
      addTearDown(account.dispose);
      final api = CoreEnergyPriorityApi(
        account: account,
        isCurrent: () => true,
        random: Random(4),
      );
      final snapshot = await api.load();
      final preview = await api.preview(snapshot, snapshot.slots.first);
      final receipt = await api.confirm(preview);
      final readback = await api.readback(preview);
      expect(receipt.exactFor(preview), isTrue);
      expect(readback, receipt);
      expect(requests, hasLength(4));
      expect(
        requests.every(
          (request) => request.headers['authorization'] == 'Bearer ${'a' * 43}',
        ),
        isTrue,
      );
    },
  );

  test('changed session family response retires the adapter', () async {
    var calls = 0;
    final account = await _account((request) async {
      if (request.url.path.endsWith('/auth/login') ||
          request.url.path.endsWith('/context')) {
        return _session(request);
      }
      calls++;
      return _json(_snapshot(sessionFamilyId: calls == 1 ? family : 'f' * 32));
    });
    addTearDown(account.dispose);
    final api = CoreEnergyPriorityApi(account: account, isCurrent: () => true);
    await api.load();
    await expectLater(api.load(), throwsA(isA<LarenorServerException>()));
    expect(api.boundSession, isNull);
  });
}
