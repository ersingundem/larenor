import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';

void main() {
  const baseUrl = 'http://homeassistant.local:8123';
  const token = 'test-token';

  group('checkConnection', () {
    test('returns true on 200', () async {
      final client = HaRestClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/');
          expect(request.headers['Authorization'], 'Bearer $token');
          return http.Response('{"message": "API running."}', 200);
        }),
      );

      expect(await client.checkConnection(), isTrue);
    });

    test('throws on 401', () async {
      final client = HaRestClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((request) async => http.Response('', 401)),
      );

      expect(client.checkConnection(), throwsA(isA<HaApiException>()));
    });

    test('throws on unexpected status codes', () async {
      final client = HaRestClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );

      expect(client.checkConnection(), throwsA(isA<HaApiException>()));
    });
  });

  group('getStates', () {
    test('parses the states list', () async {
      final client = HaRestClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/states');
          return http.Response(
            jsonEncode([
              {'entity_id': 'light.kitchen', 'state': 'on'},
              {'entity_id': 'sensor.temp', 'state': '21.0'},
            ]),
            200,
          );
        }),
      );

      final states = await client.getStates();
      expect(states, hasLength(2));
      expect(states.first.entityId, 'light.kitchen');
    });
  });

  group('callService', () {
    test(
      'posts to the domain/service endpoint with entity_id in the body',
      () async {
        final client = HaRestClient(
          baseUrl: baseUrl,
          token: token,
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/api/services/light/turn_on');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['entity_id'], 'light.kitchen');
            return http.Response('', 200);
          }),
        );

        await client.callService('light', 'turn_on', entityId: 'light.kitchen');
      },
    );
  });
}
