import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oikos/features/media/bazarr/data/bazarr_client.dart';
import 'package:oikos/features/media/bazarr/data/bazarr_config.dart';
import 'package:oikos/features/media/data/media_api_exception.dart';

void main() {
  const config = BazarrConfig(
    baseUrl: 'http://bazarr.local:6767',
    apiKey: 'key1',
  );

  group('getMissingMovieSubtitles', () {
    test(
      'sends the API key header and unwraps a {data: []} envelope',
      () async {
        final client = BazarrClient(
          config: config,
          httpClient: MockClient((request) async {
            expect(request.url.path, '/api/movies/wanted');
            expect(request.headers['X-API-KEY'], 'key1');
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'radarrId': 1,
                    'title': 'The Matrix',
                    'missing_subtitles': [],
                  },
                ],
              }),
              200,
            );
          }),
        );

        final items = await client.getMissingMovieSubtitles();
        expect(items, hasLength(1));
        expect(items.first.title, 'The Matrix');
      },
    );

    test('handles a raw array response', () async {
      final client = BazarrClient(
        config: config,
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode([
              {'radarrId': 1, 'title': 'X'},
            ]),
            200,
          );
        }),
      );

      final items = await client.getMissingMovieSubtitles();
      expect(items, hasLength(1));
    });
  });

  group('searchMovieSubtitle', () {
    test('PATCHes radarrid/language/forced/hi as form fields', () async {
      final client = BazarrClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.method, 'PATCH');
          expect(request.url.path, '/api/movies/subtitles');
          expect(request.bodyFields['radarrid'], '1');
          expect(request.bodyFields['language'], 'en');
          expect(request.bodyFields['forced'], 'false');
          expect(request.bodyFields['hi'], 'false');
          return http.Response('', 200);
        }),
      );

      await client.searchMovieSubtitle(radarrId: 1, language: 'en');
    });
  });

  group('searchEpisodeSubtitle', () {
    test('PATCHes seriesid/episodeid/language', () async {
      final client = BazarrClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/episodes/subtitles');
          expect(request.bodyFields['seriesid'], '5');
          expect(request.bodyFields['episodeid'], '6');
          return http.Response('', 200);
        }),
      );

      await client.searchEpisodeSubtitle(
        seriesId: 5,
        episodeId: 6,
        language: 'en',
      );
    });

    test('throws MediaApiException on failure', () async {
      final client = BazarrClient(
        config: config,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );

      expect(
        client.searchEpisodeSubtitle(seriesId: 1, episodeId: 2, language: 'en'),
        throwsA(isA<MediaApiException>()),
      );
    });
  });

  group('checkConnection', () {
    test('throws on a non-200 status', () async {
      final client = BazarrClient(
        config: config,
        httpClient: MockClient((request) async => http.Response('', 401)),
      );
      expect(client.checkConnection(), throwsA(isA<MediaApiException>()));
    });
  });
}
