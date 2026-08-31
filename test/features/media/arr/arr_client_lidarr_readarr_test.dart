import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oikos/features/media/arr/data/arr_client.dart';
import 'package:oikos/features/media/arr/data/arr_config.dart';
import 'package:oikos/features/media/arr/data/models/arr_lookup_result.dart';

void main() {
  const config = ArrConfig(baseUrl: 'http://lidarr.local:8686', apiKey: 'k1');

  ArrClient lidarrClient(http.Client httpClient) => ArrClient(
    config: config,
    resourcePath: 'artist',
    idFieldName: 'foreignArtistId',
    apiVersion: 'v1',
    httpClient: httpClient,
  );

  group('apiVersion', () {
    test(
      'uses /api/v1 for Lidarr instead of the Sonarr/Radarr default v3',
      () async {
        final client = lidarrClient(
          MockClient((request) async {
            expect(request.url.path, '/api/v1/artist/lookup');
            return http.Response(jsonEncode([]), 200);
          }),
        );
        await client.lookup('some artist');
      },
    );

    test(
      'defaults to v3 when not specified (Sonarr/Radarr unaffected)',
      () async {
        final client = ArrClient(
          config: config,
          resourcePath: 'series',
          idFieldName: 'tvdbId',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/api/v3/series/lookup');
            return http.Response(jsonEncode([]), 200);
          }),
        );
        await client.lookup('breaking bad');
      },
    );
  });

  group('getMetadataProfiles', () {
    test('parses the metadataprofile list', () async {
      final client = lidarrClient(
        MockClient((request) async {
          expect(request.url.path, '/api/v1/metadataprofile');
          return http.Response(
            jsonEncode([
              {'id': 1, 'name': 'Standard'},
            ]),
            200,
          );
        }),
      );
      final profiles = await client.getMetadataProfiles();
      expect(profiles.single.name, 'Standard');
    });
  });

  group('add', () {
    test(
      'includes metadataProfileId and uses searchForMissingAlbums for artist',
      () async {
        final client = lidarrClient(
          MockClient((request) async {
            expect(request.url.path, '/api/v1/artist');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['metadataProfileId'], 7);
            expect(body['addOptions'], {
              'searchForMissingAlbums': true,
              'monitor': 'all',
            });
            return http.Response('', 201);
          }),
        );

        final lookupResult = ArrLookupResult.fromJson({
          'title': 'Radiohead',
          'foreignArtistId': 'abc-123',
        }, idFieldName: 'foreignArtistId');

        await client.add(
          result: lookupResult,
          qualityProfileId: 1,
          rootFolderPath: '/music',
          metadataProfileId: 7,
        );
      },
    );

    test('uses searchForMissingBooks for author, omits metadataProfileId when null', () async {
      final client = ArrClient(
        config: config,
        resourcePath: 'author',
        idFieldName: 'foreignAuthorId',
        apiVersion: 'v1',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.containsKey('metadataProfileId'), isFalse);
          expect(body['addOptions'], {
            'searchForMissingBooks': true,
            'monitor': 'all',
          });
          return http.Response('', 201);
        }),
      );

      final lookupResult = ArrLookupResult.fromJson({
        'title': 'Some Author',
        'foreignAuthorId': 'xyz-789',
      }, idFieldName: 'foreignAuthorId');

      await client.add(
        result: lookupResult,
        qualityProfileId: 1,
        rootFolderPath: '/books',
      );
    });
  });
}
