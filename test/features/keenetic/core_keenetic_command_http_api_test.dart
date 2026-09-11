import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/keenetic/core_command/core_keenetic_command.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  test('target discovery binds exact descriptor revision tuple', () async {
    final target = CoreKeeneticCommandTarget.syntheticForTest(
      targetKind: 'guest_wifi',
      targetId: 'Guest',
      value: 'disabled',
    );
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, endsWith('/keenetic/commands/targets'));
      return http.Response(
        jsonEncode({
          'descriptors': [
            {
              'target': target.toJson(),
              'actions': ['guest_wifi_enable'],
              'expectedUserRevision': 9,
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final authority = HttpCoreKeeneticCommandAuthority(
      server: LarenorServerApi(
        endpoint: ServerEndpoint('https://core.invalid'),
        client: client,
      ),
      accessToken: 'token',
      coreId: '1' * 32,
      homeId: '2' * 32,
      resourceId: '3' * 32,
    );
    final descriptors = await authority.targets();
    expect(descriptors.single.target.fingerprint, target.fingerprint);
    expect(descriptors.single.expectedUserRevision, 9);
    expect(descriptors.single.actions, [
      CoreKeeneticCommandAction.guestWifiEnable,
    ]);
  });

  test(
    'HTTP API binds exact target and never retries a mutating request',
    () async {
      final seen = <http.Request>[];
      final target = CoreKeeneticCommandTarget.syntheticForTest(
        targetKind: 'guest_wifi',
        targetId: 'Guest',
        value: 'disabled',
      );
      final client = MockClient((request) async {
        seen.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['target'], target.toJson());
        expect(body['expectedUserRevision'], 9);
        return http.Response(
          jsonEncode({
            'preview': {
              'id': '7' * 32,
              'confirmToken': 'A' * 43,
              'requestId': body['requestId'],
              'action': 'guest_wifi_enable',
              'risk': 'low',
              'status': 'accepted',
              'target': target.toJson(),
              'expiresInMs': 60000,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = HttpCoreKeeneticCommandApi(
        server: LarenorServerApi(
          endpoint: ServerEndpoint('https://core.invalid'),
          client: client,
        ),
        accessToken: 'token',
        expectedUserRevision: 9,
      );
      final preview = await api.preview(
        CoreKeeneticCommandAction.guestWifiEnable,
        target,
      );
      expect(preview.requestId.length, 32);
      expect(seen, hasLength(1));
    },
  );

  test('malformed or secret-bearing receipt fails closed', () async {
    final target = CoreKeeneticCommandTarget.syntheticForTest(
      targetKind: 'guest_wifi',
      targetId: 'Guest',
      value: 'disabled',
    );
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'receipt': {
            'requestId': '7' * 32,
            'action': 'guest_wifi_enable',
            'target': target.toJson(),
            'status': 'succeeded',
            'code': 'succeeded',
            'transitions': ['accepted', 'executing', 'succeeded'],
            'confirmToken': 'secret',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final api = HttpCoreKeeneticCommandApi(
      server: LarenorServerApi(
        endpoint: ServerEndpoint('https://core.invalid'),
        client: client,
      ),
      accessToken: 'token',
      expectedUserRevision: 9,
    );
    expect(
      () => api.parseConfirmForTest({
        'receipt': {
          'requestId': '7' * 32,
          'action': 'guest_wifi_enable',
          'target': target.toJson(),
          'status': 'succeeded',
          'code': 'succeeded',
          'transitions': ['accepted', 'executing', 'succeeded'],
          'confirmToken': 'secret',
        },
      }),
      throwsA(isA<CoreKeeneticCommandFailure>()),
    );
  });
}
