import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/power_budget/data/power_budget_api.dart';
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

void main() {
  test(
    'client binds authenticated Core snapshot and rejects command capability',
    () async {
      const core = '11111111111111111111111111111111';
      const home = '22222222222222222222222222222222';
      const accountId = '33333333333333333333333333333333';
      final requests = <http.Request>[];
      final account = ServerAccountController(
        store: _Store(),
        apiFactory: (endpoint) => LarenorServerApi(
          endpoint: endpoint,
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('/auth/login')) {
              return json({
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
              return json({'schemaVersion': 1, 'coreId': core, 'homeId': home});
            }
            return json({
              'snapshot': {
                'schemaVersion': 1,
                'authority': {
                  'coreId': core,
                  'homeId': home,
                  'accountId': accountId,
                  'sessionId': 'session',
                  'coreRevision': 1,
                  'homeRevision': 2,
                  'accountRevision': 3,
                  'meterId': 'meter',
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
                  'id': 'plan',
                  'status': 'ready',
                  'planHash': 'c' * 64,
                  'planRevision': 9,
                  'requiredReductionW': 3500,
                  'overrideExpiresAtMs': null,
                  'actions': [
                    {
                      'loadId': 'charger',
                      'label': 'EV charger',
                      'loadRevision': 1,
                      'reductionW': 3000,
                      'targetW': 0,
                      'priority': 10,
                    },
                  ],
                },
                'controlCapability': 'manual_required',
                'commandEndpointAvailable': false,
              },
            });
          }),
        ),
      );
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: 'https://core.invalid',
        username: 'admin',
        password: 'synthetic-password',
        deviceName: 'tablet',
      );
      final api = CorePowerBudgetApi(
        account: account,
        routeId: 'route',
        sessionRevision: 1,
        routeRevision: 2,
        isCurrent: () => true,
      );
      final snapshot = await api.load();
      expect(snapshot.actions.single.label, 'EV charger');
      expect(snapshot.commandEndpointAvailable, isFalse);
      expect(requests.last.method, 'GET');
      expect(requests.last.url.path, '/api/v1/admin/power-budget');
      expect(requests.last.headers['authorization'], 'Bearer ${'a' * 43}');
    },
  );
}
