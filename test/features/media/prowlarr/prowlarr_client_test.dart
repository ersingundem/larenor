import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oikos/features/media/data/media_api_exception.dart';
import 'package:oikos/features/media/prowlarr/data/models/prowlarr_indexer.dart';
import 'package:oikos/features/media/prowlarr/data/prowlarr_client.dart';
import 'package:oikos/features/media/prowlarr/data/prowlarr_config.dart';

void main() {
  const config = ProwlarrConfig(
    baseUrl: 'http://prowlarr.local:9696',
    apiKey: 'key1',
  );

  group('getIndexers', () {
    test('hits /api/v1/indexer with the API key header', () async {
      final client = ProwlarrClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/indexer');
          expect(request.headers['X-Api-Key'], 'key1');
          return http.Response(
            jsonEncode([
              {'id': 1, 'name': '1337x', 'enable': true},
            ]),
            200,
          );
        }),
      );

      final indexers = await client.getIndexers();
      expect(indexers, hasLength(1));
      expect(indexers.first.name, '1337x');
    });
  });

  group('setIndexerEnabled', () {
    test('PUTs the full raw object back with enable flipped', () async {
      final client = ProwlarrClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.method, 'PUT');
          expect(request.url.path, '/api/v1/indexer/3');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['name'], '1337x');
          expect(body['appProfileId'], 1);
          expect(body['enable'], isFalse);
          return http.Response('', 200);
        }),
      );

      final indexer = ProwlarrIndexer.fromJson({
        'id': 3,
        'name': '1337x',
        'enable': true,
        'appProfileId': 1,
      });

      await client.setIndexerEnabled(indexer, false);
    });
  });

  group('checkConnection', () {
    test('throws on a non-200 status', () async {
      final client = ProwlarrClient(
        config: config,
        httpClient: MockClient((request) async => http.Response('', 401)),
      );
      expect(client.checkConnection(), throwsA(isA<MediaApiException>()));
    });
  });
}
