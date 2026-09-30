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
    'canSetReserve': false,
    'controlSemantics': 'exact_power',
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

Map<String, Object?> _reserveSnapshot() {
  final value = jsonDecode(jsonEncode(_snapshot())) as Map<String, dynamic>;
  value['inverter'] = {
    'schemaVersion': 1,
    'inverterId': inverter,
    'revision': 12,
    'canCharge': false,
    'canDischarge': false,
    'writable': true,
    'physicalAcceptance': 'manual',
    'canSetReserve': true,
    'controlSemantics': 'reserve_percent',
  };
  return value;
}

Map<String, Object?> _reserveResult(String requestId) => {
  'schemaVersion': 1,
  'requestId': requestId,
  'status': 'confirmed',
  'targetReservePercent': 40,
  'observedReservePercent': 40,
  'bindingRevision': 4,
};

Map<String, Object?> _backtest() => {
  'schemaVersion': 1,
  'analysisDigest': 'c' * 64,
  'authority': {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
    'homeRevision': 1,
    'accountId': accountId,
    'accountRevision': 2,
    'memberRevision': 2,
    'sessionFamilyId': family,
    'role': 'admin',
    'active': true,
    'canPlan': true,
    'canControl': true,
  },
  'serviceId': 'd' * 32,
  'serviceRevision': 4,
  'batteryId': battery,
  'batteryRevision': 8,
  'batteryProviderRevision': 9,
  'reserveRevision': 10,
  'reservePercent': 40,
  'capacityWh': 10000,
  'historyDigest': 'e' * 64,
  'capturedAtMs': 604800000,
  'startsAtMs': 0,
  'endsAtMs': 604800000,
  'slotDurationSeconds': 3600,
  'expectedSampleCount': 168,
  'sampleCount': 168,
  'missingSampleCount': 0,
  'belowReserveSampleCount': 1,
  'forecastRecordCount': 168,
  'minimumObservedSocPercent': 39.0,
  'observedStatus': 'sample_below_reserve',
  'sampleCoverage': 'complete',
  'forecastCoverage': 'complete',
  'manualPreference': 'none_current',
  'historicalPreferenceCoverage': 'unavailable',
  'historicalCapacityCoverage': 'unavailable',
  'historicalReservePolicyCoverage': 'unavailable',
  'uncertaintyReasons': [
    'historical_preferences_unavailable',
    'historical_capacity_unavailable',
    'historical_reserve_policy_unavailable',
  ],
  'slots': [
    for (var index = 0; index < 168; index++)
      {
        'schemaVersion': 1,
        'startsAtMs': index * 3600000,
        'endsAtMs': (index + 1) * 3600000,
        'observedSocPercent': index == 0 ? 39.0 : 55.0,
        'forecastRecorded': true,
        'status': index == 0 ? 'below' : 'above_or_equal',
      },
  ],
};

void main() {
  test(
    'backtest adapter accepts exact provenance and rejects malformed slots',
    () async {
      var malformed = false;
      final account = await _account((request) async {
        if (request.url.path.endsWith('/auth/login') ||
            request.url.path.endsWith('/context')) {
          return _session(request);
        }
        if (request.url.path.endsWith('/reserve-backtest')) {
          final value = _backtest();
          if (malformed) {
            (value['slots'] as List).last['status'] = 'below';
          }
          return _json(value);
        }
        return _json(_snapshot());
      });
      addTearDown(account.dispose);
      final api = CoreEnergyPriorityApi(
        account: account,
        isCurrent: () => true,
      );
      final snapshot = await api.load();
      final result = await api.loadReserveBacktest(snapshot);
      expect(result.sampleCount, 168);
      expect(result.belowReserveSampleCount, 1);
      expect(result.minimumObservedSocPercent, 39);
      expect(result.exactFor(snapshot), isTrue);
      malformed = true;
      await expectLater(
        api.loadReserveBacktest(snapshot),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );

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

  test(
    'reserve-only adapter verifies exact percent receipt and readback',
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
            !request.url.path.contains('/reserve-commands/')) {
          return _json(_reserveSnapshot());
        }
        if (request.url.path.endsWith('/reserve-previews')) {
          requestId =
              (jsonDecode(request.body) as Map<String, dynamic>)['requestId']
                  as String;
          return _json({
            'schemaVersion': 1,
            'requestId': requestId,
            'coreId': core,
            'homeId': home,
            'accountId': accountId,
            'accountRevision': 2,
            'memberRevision': 2,
            'sessionFamilyId': family,
            'inverterId': inverter,
            'inverterRevision': 12,
            'batteryId': battery,
            'batteryRevision': 8,
            'batteryProviderRevision': 9,
            'inputDigest': digest,
            'targetReservePercent': 40,
            'expiresAtMs': 100000,
            'confirmationToken': 'd' * 64,
          }, 201);
        }
        return _json(_reserveResult(requestId));
      });
      addTearDown(account.dispose);
      final api = CoreEnergyPriorityApi(
        account: account,
        isCurrent: () => true,
        random: Random(7),
      );
      final snapshot = await api.load();
      expect(snapshot.canCharge, isFalse);
      expect(snapshot.canSetReserve, isTrue);
      expect(snapshot.batteryProviderRevision, 9);
      final preview = await api.previewReserve(snapshot);
      final receipt = await api.confirmReserve(preview);
      final readback = await api.readbackReserve(preview);
      expect(receipt.exactFor(preview), isTrue);
      expect(readback, receipt);
      expect(requests, hasLength(4));
    },
  );

  test(
    'admin binds exact authenticated HA service and battery source',
    () async {
      final requests = <http.Request>[];
      final account = await _account((request) async {
        if (request.url.path.endsWith('/auth/login') ||
            request.url.path.endsWith('/context')) {
          return _session(request);
        }
        requests.add(request);
        if (request.url.path.endsWith('/admin/services')) {
          return _json({
            'services': [
              {
                'id': 'c' * 32,
                'name': 'Home Assistant',
                'kind': 'home_assistant',
                'baseUrl': 'https://ha.invalid',
                'revision': 4,
                'credentialKeys': ['token'],
                'verification': {
                  'state': 'authenticated',
                  'checkedAt': '2026-09-30T10:00:00Z',
                  'version': '2026.9.2',
                },
              },
            ],
          });
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/reserve-binding')) {
          return _json({
            'schemaVersion': 1,
            'serviceId': 'c' * 32,
            'serviceRevision': 4,
            'bindingRevision': 1,
            'batteryId': battery,
            'batteryProviderRevision': 9,
            'controlSemantics': 'reserve_percent',
            'integration': 'fronius',
            'model': 'GEN24 Plus',
          });
        }
        if (request.method == 'PUT' &&
            request.url.path.endsWith('/reserve-binding')) {
          return _json({'schemaVersion': 1, 'bindingRevision': 2});
        }
        return _json(_reserveSnapshot());
      });
      addTearDown(account.dispose);
      final api = CoreEnergyPriorityApi(
        account: account,
        isCurrent: () => true,
        random: Random(11),
      );
      final snapshot = await api.load();
      final sources = await api.loadReserveSources(snapshot);
      expect(sources, hasLength(1));
      expect(sources.single.boundModel, 'GEN24 Plus');
      await api.acceptReserveSource(
        snapshot,
        sources.single,
        'number.gen24_battery_minimum_reserve',
      );
      final put = requests.singleWhere((request) => request.method == 'PUT');
      expect(jsonDecode(put.body), {
        'schemaVersion': 1,
        'expectedServiceRevision': 4,
        'expectedBindingRevision': 1,
        'batteryId': battery,
        'batteryProviderRevision': 9,
        'reserveEntityId': 'number.gen24_battery_minimum_reserve',
      });
    },
  );
}
