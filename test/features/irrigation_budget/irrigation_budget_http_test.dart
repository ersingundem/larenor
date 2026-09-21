import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/irrigation_budget/data/irrigation_budget_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<Never?> read() async => null;
  @override
  Future<void> write(Object? session) async {}
}

http.Response json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> snapshot({String capability = 'manual_required'}) => {
  'schemaVersion': 1,
  'authority': {
    'schemaVersion': 1,
    'coreId': '1' * 32,
    'homeId': '2' * 32,
    'homeRevision': 2,
    'accountId': '3' * 32,
    'accountRevision': 3,
    'sessionFamilyId': '4' * 32,
    'role': 'admin',
    'active': true,
    'canManageIrrigation': true,
  },
  'policyId': '5' * 32,
  'policyRevision': 4,
  'planId': '6' * 32,
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
      'zoneId': '7' * 32,
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
  'controlCapability': capability,
  'commandEndpointAvailable': false,
};

Future<ServerAccountController> accountFor(
  Future<http.Response> Function(http.Request) handler,
) async {
  final account = ServerAccountController(
    store: _Store(),
    apiFactory: (endpoint) => LarenorServerApi(
      endpoint: endpoint,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return json({
            'accessToken': 'a' * 43,
            'refreshToken': 'b' * 43,
            'expiresIn': 3600,
            'user': {
              'id': '3' * 32,
              'username': 'admin',
              'role': 'admin',
              'mustChangePassword': false,
            },
          });
        }
        if (request.url.path.endsWith('/context')) {
          return json({
            'schemaVersion': 1,
            'coreId': '1' * 32,
            'homeId': '2' * 32,
          });
        }
        return handler(request);
      }),
    ),
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
  test('loads exact authenticated read-only irrigation projection', () async {
    final requests = <http.Request>[];
    final account = await accountFor((request) async {
      requests.add(request);
      return json({'snapshot': snapshot()});
    });
    addTearDown(account.dispose);
    final api = CoreIrrigationBudgetApi(
      account: account,
      routeId: 'route',
      sessionRevision: 8,
      routeRevision: 9,
      isCurrent: () => true,
    );
    final value = await api.load();
    expect(value.zones.single.areaName, 'Back garden');
    expect(value.zones.single.plantName, 'Tomatoes');
    expect(value.commandEndpointAvailable, isFalse);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/api/v1/admin/irrigation-budget');
    expect(requests.single.headers['authorization'], 'Bearer ${'a' * 43}');
  });

  test('rejects command capability and foreign Core authority', () async {
    for (final invalid in [
      snapshot(capability: 'write'),
      {...snapshot(), 'authority': {...snapshot()['authority'] as Map<String, dynamic>, 'coreId': 'f' * 32}},
    ]) {
      final account = await accountFor((_) async => json({'snapshot': invalid}));
      final api = CoreIrrigationBudgetApi(
        account: account,
        routeId: 'route',
        sessionRevision: 1,
        routeRevision: 1,
        isCurrent: () => true,
      );
      await expectLater(api.load(), throwsA(isA<Exception>()));
      account.dispose();
    }
  });
}
