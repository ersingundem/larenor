import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oikos/features/media/arr/data/arr_client.dart';
import 'package:oikos/features/media/arr/data/arr_config.dart';
import 'package:oikos/features/media/arr/data/models/arr_lookup_result.dart';
import 'package:oikos/features/media/data/media_api_exception.dart';

void main() {
  const config = ArrConfig(baseUrl: 'http://sonarr.local:8989', apiKey: 'k1');

  ArrClient sonarrClient(http.Client httpClient) => ArrClient(
    config: config,
    resourcePath: 'series',
    idFieldName: 'tvdbId',
    httpClient: httpClient,
  );

  ArrClient radarrClient(http.Client httpClient) => ArrClient(
    config: config,
    resourcePath: 'movie',
    idFieldName: 'tmdbId',
    httpClient: httpClient,
  );

  group('lookup', () {
    test(
      'hits the resource-specific lookup endpoint with the API key header',
      () async {
        final client = sonarrClient(
          MockClient((request) async {
            expect(request.url.path, '/api/v3/series/lookup');
            expect(request.url.queryParameters['term'], 'breaking bad');
            expect(request.headers['X-Api-Key'], 'k1');
            return http.Response(
              jsonEncode([
                {'title': 'Breaking Bad', 'tvdbId': 81189},
              ]),
              200,
            );
          }),
        );

        final results = await client.lookup('breaking bad');
        expect(results, hasLength(1));
        expect(results.first.title, 'Breaking Bad');
      },
    );
  });

  group('getQualityProfiles / getRootFolders', () {
    test('parses profile and folder lists', () async {
      final client = sonarrClient(
        MockClient((request) async {
          if (request.url.path == '/api/v3/qualityprofile') {
            return http.Response(
              jsonEncode([
                {'id': 1, 'name': 'HD-1080p'},
              ]),
              200,
            );
          }
          return http.Response(
            jsonEncode([
              {'id': 1, 'path': '/tv'},
            ]),
            200,
          );
        }),
      );

      final profiles = await client.getQualityProfiles();
      expect(profiles.single.name, 'HD-1080p');

      final folders = await client.getRootFolders();
      expect(folders.single.path, '/tv');
    });
  });

  group('add', () {
    test(
      'spreads raw lookup fields and merges add fields for a series',
      () async {
        final client = sonarrClient(
          MockClient((request) async {
            expect(request.url.path, '/api/v3/series');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['title'], 'Breaking Bad');
            expect(body['tvdbId'], 81189);
            expect(body['qualityProfileId'], 4);
            expect(body['rootFolderPath'], '/tv');
            expect(body['monitored'], isTrue);
            expect(body['addOptions'], {
              'searchForMissingEpisodes': true,
              'monitor': 'all',
            });
            return http.Response('', 201);
          }),
        );

        final lookupResult = ArrLookupResult.fromJson({
          'title': 'Breaking Bad',
          'tvdbId': 81189,
        }, idFieldName: 'tvdbId');

        await client.add(
          result: lookupResult,
          qualityProfileId: 4,
          rootFolderPath: '/tv',
        );
      },
    );

    test('uses searchForMovie addOptions for a movie resource', () async {
      final client = radarrClient(
        MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['addOptions'], {'searchForMovie': false});
          return http.Response('', 201);
        }),
      );

      final lookupResult = ArrLookupResult.fromJson({
        'title': 'The Matrix',
        'tmdbId': 603,
      }, idFieldName: 'tmdbId');

      await client.add(
        result: lookupResult,
        qualityProfileId: 1,
        rootFolderPath: '/movies',
        searchOnAdd: false,
      );
    });

    test('throws MediaApiException on failure', () async {
      final client = radarrClient(
        MockClient((request) async => http.Response('bad request', 400)),
      );
      final lookupResult = ArrLookupResult.fromJson({
        'title': 'X',
        'tmdbId': 1,
      }, idFieldName: 'tmdbId');

      expect(
        client.add(
          result: lookupResult,
          qualityProfileId: 1,
          rootFolderPath: '/movies',
        ),
        throwsA(isA<MediaApiException>()),
      );
    });
  });

  group('getQueue', () {
    test('handles a {records: []} envelope', () async {
      final client = sonarrClient(
        MockClient((request) async {
          expect(request.url.path, '/api/v3/queue');
          return http.Response(
            jsonEncode({
              'records': [
                {'id': 1, 'title': 'Episode 1', 'status': 'downloading'},
              ],
            }),
            200,
          );
        }),
      );

      final queue = await client.getQueue();
      expect(queue, hasLength(1));
    });

    test('handles a raw array response', () async {
      final client = sonarrClient(
        MockClient((request) async {
          return http.Response(
            jsonEncode([
              {'id': 1, 'title': 'Episode 1', 'status': 'downloading'},
            ]),
            200,
          );
        }),
      );

      final queue = await client.getQueue();
      expect(queue, hasLength(1));
    });
  });

  group('getCalendar', () {
    test('parses calendar entries', () async {
      final client = sonarrClient(
        MockClient((request) async {
          expect(request.url.path, '/api/v3/calendar');
          expect(request.url.queryParameters['includeSeries'], 'true');
          return http.Response(
            jsonEncode([
              {
                'title': 'Pilot',
                'series': {'title': 'Breaking Bad'},
              },
            ]),
            200,
          );
        }),
      );

      final calendar = await client.getCalendar();
      expect(calendar.single.title, 'Breaking Bad');
    });
  });

  group('checkConnection', () {
    test('throws when the status endpoint does not return 200', () async {
      final client = sonarrClient(
        MockClient((request) async => http.Response('', 401)),
      );
      expect(client.checkConnection(), throwsA(isA<MediaApiException>()));
    });
  });
}
