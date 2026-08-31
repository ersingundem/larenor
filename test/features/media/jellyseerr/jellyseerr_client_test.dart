import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';

void main() {
  const config = JellyseerrConfig(
    baseUrl: 'http://jellyseerr.local:5055',
    apiKey: 'key123',
  );

  group('search', () {
    test('sends the API key header and filters to movie/tv results', () async {
      final client = JellyseerrClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/search');
          expect(request.url.queryParameters['query'], 'matrix');
          expect(request.headers['X-Api-Key'], 'key123');
          return http.Response(
            jsonEncode({
              'results': [
                {'id': 1, 'mediaType': 'movie', 'title': 'The Matrix'},
                {'id': 2, 'mediaType': 'person', 'name': 'Someone'},
                {'id': 3, 'mediaType': 'tv', 'name': 'Show'},
              ],
            }),
            200,
          );
        }),
      );

      final results = await client.search('matrix');
      expect(results, hasLength(2));
      expect(results.map((r) => r.id), [1, 3]);
    });
  });

  group('requestMedia', () {
    test('posts mediaType/mediaId/seasons and succeeds on 201', () async {
      final client = JellyseerrClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/request');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['mediaType'], 'tv');
          expect(body['mediaId'], 5);
          expect(body['seasons'], [1, 2]);
          return http.Response('', 201);
        }),
      );

      await client.requestMedia(mediaType: 'tv', mediaId: 5, seasons: [1, 2]);
    });

    test('omits seasons entirely when not provided', () async {
      final client = JellyseerrClient(
        config: config,
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.containsKey('seasons'), isFalse);
          return http.Response('', 201);
        }),
      );

      await client.requestMedia(mediaType: 'movie', mediaId: 5);
    });

    test('throws on failure status codes', () async {
      final client = JellyseerrClient(
        config: config,
        httpClient: MockClient((request) async => http.Response('nope', 500)),
      );

      expect(
        client.requestMedia(mediaType: 'movie', mediaId: 5),
        throwsA(isA<MediaApiException>()),
      );
    });
  });

  group('myRequests', () {
    test('parses the results envelope', () async {
      final client = JellyseerrClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/request');
          return http.Response(
            jsonEncode({
              'results': [
                {'id': 1, 'type': 'movie', 'status': 1},
              ],
            }),
            200,
          );
        }),
      );

      final requests = await client.myRequests();
      expect(requests, hasLength(1));
      expect(requests.first.id, 1);
    });
  });

  group('posterUrl', () {
    test('builds a TMDB image URL, or null when there is no path', () {
      final client = JellyseerrClient(config: config);
      expect(
        client.posterUrl('/abc.jpg'),
        'https://image.tmdb.org/t/p/w300/abc.jpg',
      );
      expect(client.posterUrl(null), isNull);
    });
  });
}
