import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/data/server_services_api.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

void main() {
  test(
    'Client consumes the exact wire lifecycle verified by FastAPI',
    () async {
      final fixture = jsonDecode(
        File('contracts/service-connections.v1.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final requests = <http.Request>[];
      var index = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://larenor.example.test/server'),
        client: MockClient((request) async {
          requests.add(request);
          final responseKey = [
            'createdResponse',
            'updatedResponse',
            'checkedResponse',
            null,
          ][index++];
          return http.Response(
            responseKey == null ? '' : jsonEncode(fixture[responseKey]),
            responseKey == null
                ? 204
                : index == 1
                ? 201
                : 200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.close);
      final services = ServerServicesApi(api, 'synthetic-session-access-token');
      final input = fixture['createRequest'] as Map<String, dynamic>;
      final created = await services.create(
        name: input['name'],
        kind: ServerServiceKind.homeAssistant,
        baseUrl: input['baseUrl'],
        credentials: Map<String, String>.from(input['credentials']),
      );
      final update = fixture['updateRequest'] as Map<String, dynamic>;
      final updated = await services.update(
        created,
        name: update['name'],
        baseUrl: update['baseUrl'],
      );
      final checked = await services.check(updated);
      await services.forget(checked);
      expect(checked.revision, 2);
      expect(
        checked.verification.state,
        ServerServiceVerificationState.authenticated,
      );
      expect(checked.verification.checkedAt, DateTime.utc(2026, 9, 5, 12));
      expect(checked.baseUrl, input['baseUrl']);
      for (var i = 0; i < 3; i++) {
        expect(
          jsonDecode(requests[i].body),
          fixture[['createRequest', 'updateRequest', 'checkRequest'][i]],
        );
      }
      expect(requests.map((request) => request.method), [
        'POST',
        'PATCH',
        'POST',
        'DELETE',
      ]);
      expect(requests.last.url.queryParameters, {'expectedRevision': '2'});
      expect(
        requests.every(
          (request) =>
              request.url.path.startsWith('/server/api/v1/admin/services'),
        ),
        isTrue,
      );
      expect(
        requests.every(
          (request) => !request.url.toString().contains('synthetic'),
        ),
        isTrue,
      );
    },
  );
}
