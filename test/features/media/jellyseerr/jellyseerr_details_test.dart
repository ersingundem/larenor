import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_details.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_result.dart';

void main() {
  test(
    'direct TV GET preserves proxy prefix and separates season facts',
    () async {
      final client = JellyseerrClient(
        config: const JellyseerrConfig(
          baseUrl: 'https://catalogue.test/seerr',
          apiKey: 'fixture',
        ),
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/seerr/api/v1/tv/42');
          expect(request.headers['X-Api-Key'], 'fixture');
          return http.Response(
            jsonEncode({
              'id': 42,
              'name': 'Series',
              'seasons': [
                {'seasonNumber': 2, 'episodeCount': 8},
                {'seasonNumber': 1, 'episodeCount': 10},
              ],
              'mediaInfo': {
                'status': 4,
                'seasons': [
                  {'seasonNumber': 1, 'status': 5},
                  {'seasonNumber': 2, 'status': 2},
                ],
              },
            }),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      final details = await client.getDetails(mediaType: 'tv', mediaId: 42);
      expect(details.result.status, JellyseerrMediaStatus.partiallyAvailable);
      expect(details.result.mediaInfo?.jellyfinMediaId, isNull);
      expect(details.seasons.map((s) => s.seasonNumber), [1, 2]);
      expect(details.seasons.last.episodeCount, 8);
      expect(details.seasons.last.status, JellyseerrMediaStatus.pending);
    },
  );

  test(
    'unknown season coverage stays unknown rather than zero or complete',
    () {
      final details = JellyseerrDetails.fromJson(
        {
          'id': 42,
          'name': 'Series',
          'mediaInfo': {
            'seasons': [
              {'seasonNumber': 1, 'status': 5},
            ],
          },
        },
        mediaType: 'tv',
        mediaId: 42,
      );
      expect(details.seasons.single.episodeCount, isNull);
      expect(details.seasons.single.airDate, isNull);
      expect(details.seasons.single.status, JellyseerrMediaStatus.available);
    },
  );

  test('malformed and conflicting identity/season responses fail', () {
    for (final body in <Map<String, dynamic>>[
      {'id': 43, 'name': 'Series'},
      {'id': 42, 'name': ''},
      {'id': 42, 'name': 'Series', 'mediaType': 'movie'},
      {
        'id': 42,
        'name': 'Series',
        'mediaInfo': {'tmdbId': 43},
      },
      {'id': 42, 'name': 'Series', 'seasons': {}},
      {
        'id': 42,
        'name': 'Series',
        'seasons': [
          {'seasonNumber': 1, 'episodeCount': -1},
        ],
      },
      {
        'id': 42,
        'name': 'Series',
        'seasons': [
          {'seasonNumber': 1},
          {'seasonNumber': 1},
        ],
      },
    ]) {
      expect(
        () => JellyseerrDetails.fromJson(body, mediaType: 'tv', mediaId: 42),
        throwsFormatException,
      );
    }
  });

  test('invalid route inputs cause zero requests', () async {
    var requests = 0;
    final client = JellyseerrClient(
      config: const JellyseerrConfig(
        baseUrl: 'https://catalogue.test',
        apiKey: 'fixture',
      ),
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.getDetails(mediaType: '../auth', mediaId: 42),
      throwsArgumentError,
    );
    await expectLater(
      client.getDetails(mediaType: 'movie', mediaId: 0),
      throwsArgumentError,
    );
    expect(requests, 0);
  });

  for (final code in [401, 403, 404, 500]) {
    test(
      'details preserves HTTP $code instead of returning empty success',
      () async {
        final client = JellyseerrClient(
          config: const JellyseerrConfig(
            baseUrl: 'https://catalogue.test',
            apiKey: 'fixture',
          ),
          httpClient: MockClient((_) async => http.Response('{}', code)),
        );
        addTearDown(client.dispose);
        await expectLater(
          client.getDetails(mediaType: 'movie', mediaId: 42),
          throwsA(
            isA<MediaApiException>().having(
              (e) => e.statusCode,
              'status',
              code,
            ),
          ),
        );
      },
    );
  }
}
