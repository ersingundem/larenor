import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/kiosk_remote/data/kiosk_remote_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<Never?> read() async => null;
  @override
  Future<void> write(Object? session) async {}
}

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value), status, headers: {'content-type': 'application/json'});

void main() {
  test('admin inventory uses bearer auth and never decodes a pairing token', () async {
    final requests = <http.Request>[];
    final account = ServerAccountController(
      store: _Store(),
      apiFactory: (endpoint) => LarenorServerApi(
        endpoint: endpoint,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/login')) return json({
            'accessToken': 'a' * 43, 'refreshToken': 'b' * 43, 'expiresIn': 3600,
            'user': {'id': '3' * 32, 'username': 'admin', 'role': 'admin', 'mustChangePassword': false},
          });
          if (request.url.path.endsWith('/context')) return json({
            'schemaVersion': 1, 'coreId': '1' * 32, 'homeId': '2' * 32,
          });
          requests.add(request);
          if (request.url.path.endsWith('/devices')) return json({
            'schemaVersion': 1,
            'scope': {'schemaVersion': 1, 'coreId': '1' * 32, 'homeId': '2' * 32},
            'tablets': [{
              'schemaVersion': 1,
              'ref': {'schemaVersion': 1, 'coreId': '1' * 32, 'homeId': '2' * 32, 'kind': 'managed_tablet', 'id': '4' * 32},
              'revision': 1, 'name': 'Kitchen tablet', 'platform': 'android',
              'managementMode': 'standard', 'capabilities': ['kiosk'],
              'clientVersion': '1.0.0', 'desiredProfileRevision': 1,
              'appliedProfileRevision': 1, 'state': 'active',
              'profileState': 'current', 'lastSeenAt': 1788609600.0,
            }],
          });
          return json({'schemaVersion': 1, 'pairings': []});
        }),
      ),
    );
    addTearDown(account.dispose);
    await account.signIn(
      baseUrl: 'https://core.invalid', username: 'admin',
      password: 'synthetic-password', deviceName: 'tablet');
    final api = CoreKioskRemoteApi(
      account: account,
      sessionRevision: 1,
      routeRevision: 1,
      isCurrent: () => true,
    );
    final value = await api.load();
    expect(value.devices.single.name, 'Kitchen tablet');
    expect(value.pairings, isEmpty);
    expect(requests, hasLength(2));
    expect(requests.every((request) => request.headers['authorization'] == 'Bearer ${'a' * 43}'), isTrue);
    expect(requests.every((request) => !request.url.queryParameters.containsKey('token')), isTrue);
  });
}
