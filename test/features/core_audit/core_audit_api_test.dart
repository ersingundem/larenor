import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/core_audit/data/core_audit_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  const coreId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const homeId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  final context = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
  });

  test(
    'Core audit sends the retained checkpoint only on its fixed route',
    () async {
      final calls = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test'),
        client: MockClient((request) async {
          calls.add(request);
          return http.Response(
            jsonEncode({
              'verification': {
                'schemaVersion': 1,
                'scope': context.toJson(),
                'chainId': 'c' * 32,
                'sequence': 7,
                'headHash': 'd' * 64,
                'checkpoint': 'next-checkpoint',
                'verified': true,
                'comparedCheckpoint': true,
                'causalityVerified': false,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(transport.close);

      final proof = await CoreAuditApi(
        transport,
        'synthetic-access-token',
        context,
      ).verification(checkpoint: 'retained-checkpoint');

      expect(proof.sequence, 7);
      expect(calls.single.method, 'GET');
      expect(
        calls.single.url.path,
        '/api/v1/admin/core-audit/$coreId/$homeId/verification',
      );
      expect(calls.single.url.queryParameters, {
        'checkpoint': 'retained-checkpoint',
      });
    },
  );

  test(
    'checkpoint query cannot escape the fixed Core audit contract',
    () async {
      var calls = 0;
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint('https://server.test'),
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(transport.close);

      for (final entry in [
        ('POST', '/admin/core-audit/$coreId/$homeId/verification', 'value'),
        ('GET', '/admin/core-audit/$coreId/$homeId', 'value'),
        ('GET', '/admin/core-audit/$coreId/$homeId/verification', ''),
        ('GET', '/admin/core-audit/$coreId/$homeId/verification', 'has space'),
        ('GET', '/admin/core-audit/$coreId/$homeId/verification', 'x' * 513),
      ]) {
        await expectLater(
          transport.request(
            entry.$1,
            entry.$2,
            queryParameters: {'checkpoint': entry.$3},
          ),
          throwsA(
            isA<LarenorServerException>().having(
              (error) => error.code,
              'code',
              'invalid_request',
            ),
          ),
        );
      }
      expect(calls, 0);
    },
  );
}
