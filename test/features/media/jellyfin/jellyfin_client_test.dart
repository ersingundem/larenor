import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';

void main() {
  const baseUrl = 'http://jellyfin.local:8096';
  const config = JellyfinConfig(
    baseUrl: baseUrl,
    userId: 'user1',
    accessToken: 'token1',
    deviceId: 'device1',
  );

  group('TV browsing and complete library index', () {
    test('includeMissing omits missing-only filter and preserves specials metadata', () async {
      final client = JellyfinClient(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters.containsKey('IsMissing'), isFalse);
          expect(request.url.queryParameters['UserId'], config.userId);
          return http.Response(
            jsonEncode({
              'Items': [
                {
                  'Id': 'special',
                  'Name': 'Special',
                  'Type': 'Episode',
                  'IndexNumber': 1,
                  'ParentIndexNumber': 0,
                  'LocationType': 'Virtual',
                  'PlayAccess': 'Full',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      await client.getSeasons('series', includeMissing: true);
      final items = await client.getEpisodes(
        'series',
        seasonId: 'specials',
        includeMissing: true,
      );
      expect(items.single.parentIndexNumber, 0);
      expect(items.single.isVirtual, isTrue);
      expect(items.single.isPlayable, isFalse);
    });
    test(
      'requests available seasons and episodes scoped to the user',
      () async {
        final requests = <Uri>[];
        final client = JellyfinClient(
          config: config,
          httpClient: MockClient((request) async {
            requests.add(request.url);
            expect(request.url.queryParameters['UserId'], 'user1');
            expect(request.url.queryParameters['IsMissing'], 'false');
            expect(
              request.url.queryParameters['Fields'],
              isNot(contains('ImageTags')),
            );
            expect(
              request.url.queryParameters['Fields'],
              contains('PlayAccess'),
            );
            expect(
              request.url.queryParameters['Fields'],
              contains('MediaSourceCount'),
            );
            expect(
              request.url.queryParameters['Fields']!.split(','),
              isNot(contains('MediaSources')),
            );
            return http.Response('{"Items":[]}', 200);
          }),
        );
        await client.getSeasons('show1');
        await client.getEpisodes('show1', seasonId: 'season2');
        expect(requests[0].path, '/Shows/show1/Seasons');
        expect(requests[1].path, '/Shows/show1/Episodes');
        expect(requests[1].queryParameters['SeasonId'], 'season2');
      },
    );

    test('loads every index page and stops at TotalRecordCount', () async {
      final offsets = <String?>[];
      final client = JellyfinClient(
        config: config,
        httpClient: MockClient((request) async {
          final offset = int.parse(request.url.queryParameters['StartIndex']!);
          offsets.add('$offset');
          return http.Response(
            jsonEncode({
              'TotalRecordCount': 3,
              'Items': [
                for (var i = offset; i < offset + 2 && i < 3; i++)
                  {'Id': '$i', 'Name': 'Movie $i', 'Type': 'Movie'},
              ],
            }),
            200,
          );
        }),
      );
      final items = await client.getAllMoviesAndSeries(limit: 2);
      expect(items.map((item) => item.id), ['0', '1', '2']);
      expect(offsets, ['0', '2']);
    });

    test('does not loop forever if a server ignores pagination', () async {
      var calls = 0;
      final client = JellyfinClient(
        config: config,
        httpClient: MockClient((request) async {
          calls++;
          return http.Response(
            '{"TotalRecordCount":50,"Items":[{"Id":"1","Name":"Film","Type":"Movie"}]}',
            200,
          );
        }),
      );
      expect(await client.getAllMoviesAndSeries(limit: 1), hasLength(1));
      expect(calls, 2);
    });
  });

  group('login', () {
    test('sends username/password and parses the token + user id', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, '/Users/AuthenticateByName');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['Username'], 'alice');
        expect(body['Pw'], 'secret');
        expect(
          request.headers['X-Emby-Authorization'],
          contains('DeviceId="device1"'),
        );
        return http.Response(
          jsonEncode({
            'AccessToken': 'tok',
            'User': {'Id': 'u1'},
          }),
          200,
        );
      });

      final result = await JellyfinClient.login(
        baseUrl: baseUrl,
        username: 'alice',
        password: 'secret',
        deviceId: 'device1',
        httpClient: mockClient,
      );

      expect(result.accessToken, 'tok');
      expect(result.userId, 'u1');
    });

    test('throws on non-200', () async {
      final mockClient = MockClient((request) async => http.Response('', 401));
      expect(
        JellyfinClient.login(
          baseUrl: baseUrl,
          username: 'alice',
          password: 'wrong',
          deviceId: 'device1',
          httpClient: mockClient,
        ),
        throwsA(isA<MediaApiException>()),
      );
    });
  });

  group('getPlaybackInfo', () {
    for (final source in [
      {'Id': 'source'},
      {
        'Id': 'source',
        'SupportsDirectPlay': false,
        'SupportsDirectStream': false,
        'SupportsTranscoding': false,
      },
      {'Id': 'source', 'SupportsTranscoding': true},
      {'Id': 'source', 'SupportsDirectStream': true},
      {'Id': 'source', 'SupportsDirectPlay': true, 'RequiresOpening': true},
      {'Id': '', 'SupportsDirectPlay': true},
    ]) {
      test(
        'rejects unsupported source without inventing a direct URL: $source',
        () async {
          final client = JellyfinClient(
            config: config,
            httpClient: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'PlaySessionId': 'session',
                  'MediaSources': [source],
                }),
                200,
              ),
            ),
          );
          addTearDown(client.dispose);
          await expectLater(
            client.getPlaybackInfo('item'),
            throwsA(isA<MediaApiException>()),
          );
        },
      );
    }

    test(
      'server playback error overrides even an apparently valid media source',
      () async {
        final client = JellyfinClient(
          config: config,
          httpClient: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'PlaySessionId': 'session',
                'ErrorCode': 'NotAllowed',
                'MediaSources': [
                  {'Id': 'source', 'SupportsDirectPlay': true},
                ],
              }),
              200,
            ),
          ),
        );
        addTearDown(client.dispose);
        await expectLater(
          client.getPlaybackInfo('item'),
          throwsA(isA<MediaApiException>()),
        );
      },
    );

    test('skips unsupported alternatives and uses the approved direct-stream/remux URL', () async {
      final client = JellyfinClient(
        config: config,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'PlaySessionId': 'session',
              'MediaSources': [
                {'Id': 'unsupported'},
                {
                  'Id': 'remux',
                  'SupportsDirectPlay': false,
                  'SupportsDirectStream': true,
                  'SupportsTranscoding': false,
                  'TranscodingUrl': '/Videos/item/master.m3u8',
                },
              ],
            }),
            200,
          ),
        ),
      );
      addTearDown(client.dispose);
      final source = await client.getPlaybackInfo('item');
      expect(source.mediaSourceId, 'remux');
      expect(source.streamUrl, '$baseUrl/Videos/item/master.m3u8');
    });
    test(
      'uses a static URL only when the server approves direct play',
      () async {
        final client = JellyfinClient(
          config: config,
          httpClient: MockClient((request) async {
            expect(request.url.path, '/Items/item1/PlaybackInfo');
            return http.Response(
              jsonEncode({
                'PlaySessionId': 'session1',
                'MediaSources': [
                  {'Id': 'source1', 'SupportsDirectPlay': true},
                ],
              }),
              200,
            );
          }),
        );

        final source = await client.getPlaybackInfo('item1');

        expect(source.isTranscoding, isFalse);
        expect(source.mediaSourceId, 'source1');
        expect(source.playSessionId, 'session1');
        expect(source.streamUrl, contains('/Videos/item1/stream'));
        expect(source.streamUrl, contains('mediaSourceId=source1'));
      },
    );

    test(
      'prefers a server-approved direct source over a transcoding alternative',
      () async {
        final client = JellyfinClient(
          config: config,
          httpClient: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'PlaySessionId': 'session1',
                'MediaSources': [
                  {
                    'Id': 'transcode',
                    'SupportsDirectPlay': false,
                    'SupportsTranscoding': true,
                    'TranscodingUrl': '/transcode.m3u8',
                  },
                  {
                    'Id': 'direct',
                    'SupportsDirectPlay': true,
                    'TranscodingUrl': '/fallback.m3u8',
                  },
                ],
              }),
              200,
            );
          }),
        );
        final source = await client.getPlaybackInfo('item1');
        expect(source.mediaSourceId, 'direct');
        expect(source.isTranscoding, isFalse);
        expect(source.streamUrl, contains('/Videos/item1/stream'));
      },
    );

    test('uses the server-provided TranscodingUrl when present', () async {
      final client = JellyfinClient(
        config: config,
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'PlaySessionId': 'session1',
              'MediaSources': [
                {
                  'Id': 'source1',
                  'SupportsTranscoding': true,
                  'TranscodingUrl': '/videos/item1/master.m3u8?a=b',
                },
              ],
            }),
            200,
          );
        }),
      );

      final source = await client.getPlaybackInfo('item1');

      expect(source.isTranscoding, isTrue);
      expect(source.streamUrl, '$baseUrl/videos/item1/master.m3u8?a=b');
    });

    test(
      'includes MaxStreamingBitrate in the request body when given',
      () async {
        final client = JellyfinClient(
          config: config,
          httpClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['MaxStreamingBitrate'], 4000000);
            return http.Response(
              jsonEncode({
                'PlaySessionId': 'session1',
                'MediaSources': [
                  {'Id': 'source1', 'SupportsDirectPlay': true},
                ],
              }),
              200,
            );
          }),
        );

        await client.getPlaybackInfo('item1', maxStreamingBitrate: 4000000);
      },
    );

    test('omits MaxStreamingBitrate entirely when not given', () async {
      final client = JellyfinClient(
        config: config,
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.containsKey('MaxStreamingBitrate'), isFalse);
          return http.Response(
            jsonEncode({
              'PlaySessionId': 'session1',
              'MediaSources': [
                {'Id': 'source1', 'SupportsDirectPlay': true},
              ],
            }),
            200,
          );
        }),
      );

      await client.getPlaybackInfo('item1');
    });

    test('throws when there are no media sources', () async {
      final client = JellyfinClient(
        config: config,
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'PlaySessionId': 'session1',
              'MediaSources': <dynamic>[],
            }),
            200,
          );
        }),
      );

      expect(
        client.getPlaybackInfo('item1'),
        throwsA(isA<MediaApiException>()),
      );
    });
  });

  group('getLatestItems', () {
    test(
      'parses the raw array response (not an {Items: []} envelope)',
      () async {
        final client = JellyfinClient(
          config: config,
          httpClient: MockClient((request) async {
            expect(request.url.path, '/Users/user1/Items/Latest');
            return http.Response(
              jsonEncode([
                {'Id': '1', 'Name': 'A', 'Type': 'Movie'},
                {'Id': '2', 'Name': 'B', 'Type': 'Movie'},
              ]),
              200,
            );
          }),
        );

        final items = await client.getLatestItems();
        expect(items, hasLength(2));
        expect(items.first.name, 'A');
      },
    );
  });
}
