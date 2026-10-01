import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/multi_display/data/dual_display_authority_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const account = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';

ServerSession session() => ServerSession(
  endpoint: ServerEndpoint('http://127.0.0.1:9123'),
  accessToken: 'a' * 43,
  refreshToken: 'b' * 64,
  expiresAt: DateTime.utc(2027),
  user: const ServerUser(
    id: account,
    username: 'owner',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
  sessionFamilyId: family,
  context: ServerContext.fromJson(const {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
  }),
);

Map<String, Object> authority({int accountRevision = 17}) => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'accountId': account,
  'accountRevision': accountRevision,
  'homeRevision': 19,
  'sessionFamilyId': family,
  'routePolicyRevision': 2,
  'allowedSecondaryRoutes': ['core.status'],
};

Map<String, Object> snapshot({int revision = 101}) => {
  'schemaVersion': 1,
  'snapshotRevision': revision,
  'observedAtMs': 1000,
  'expiresAtMs': 16000,
  'serviceState': 'online',
  'apiVersion': 1,
  'systemLoadPercent': 12,
  'processMemoryMiB': 128,
  'dataDiskFreeBytes': 400,
  'dataDiskTotalBytes': 1000,
  'processUptimeSeconds': 30,
};

Map<String, Object> envelope({
  Map<String, Object>? authorityValue,
  Map<String, Object>? snapshotValue,
}) => {
  'schemaVersion': 1,
  'authority': authorityValue ?? authority(),
  'publicSnapshot': snapshotValue ?? snapshot(),
};

void main() {
  test(
    'parses exact Core authority and checks current before and after IO',
    () async {
      var current = true;
      var calls = 0;
      final transport = LarenorServerApi(
        endpoint: session().endpoint,
        client: MockClient((request) async {
          calls++;
          expect(request.method, 'GET');
          expect(
            request.url.path,
            '/api/v1/multi-display/$core/$home/authority',
          );
          expect(request.headers['authorization'], 'Bearer ${'a' * 43}');
          return http.Response(
            jsonEncode(envelope()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final api = DualDisplayAuthorityApi(transport, session());
      addTearDown(api.close);
      final value = await api.read(
        lifecycleEpoch: 23,
        interactionEpoch: 29,
        current: () => current,
      );
      expect(calls, 1);
      expect(value.authority.accountRevision, 17);
      expect(value.authority.homeRevision, 19);
      expect(value.authority.sessionFamilyId, family);
      expect(value.authority.lifecycleEpoch, 23);
      expect(value.authority.interactionEpoch, 29);
      expect(value.publicSnapshot.systemLoadPercent, 12);
      expect(value.publicSnapshot.dataDiskFreeBytes, 400);
      current = false;
      await expectLater(
        api.read(
          lifecycleEpoch: 23,
          interactionEpoch: 29,
          current: () => current,
        ),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(calls, 1);
    },
  );

  test(
    'rejects identity drift, extra fields, unsafe revisions and routes',
    () async {
      for (final malformed in <Map<String, Object>>[
        envelope(authorityValue: {...authority(), 'accountId': 'f' * 32}),
        {...envelope(), 'private': true},
        envelope(
          authorityValue: {
            ...authority(accountRevision: 1),
            'accountRevision': 0x20000000000000,
          },
        ),
        envelope(
          authorityValue: {
            ...authority(),
            'allowedSecondaryRoutes': ['admin.secrets'],
          },
        ),
        envelope(authorityValue: {...authority(), 'routePolicyRevision': 1}),
        envelope(snapshotValue: {...snapshot(), 'dataDiskFreeBytes': 1001}),
      ]) {
        final api = DualDisplayAuthorityApi(
          LarenorServerApi(
            endpoint: session().endpoint,
            client: MockClient(
              (_) async => http.Response(
                jsonEncode(malformed),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          ),
          session(),
        );
        addTearDown(api.close);
        await expectLater(
          api.read(lifecycleEpoch: 1, interactionEpoch: 1, current: () => true),
          throwsA(isA<LarenorServerException>()),
        );
      }
    },
  );
}
