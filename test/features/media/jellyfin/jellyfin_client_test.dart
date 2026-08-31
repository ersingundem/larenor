import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oikos/features/media/data/media_api_exception.dart';
import 'package:oikos/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:oikos/features/media/jellyfin/data/jellyfin_config.dart';

void main() {
  const baseUrl = 'http://jellyfin.local:8096';
  const config = JellyfinConfig(
    baseUrl: baseUrl,
    userId: 'user1',
    accessToken: 'token1',
    deviceId: 'device1',
  );

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
    test(
      'prefers the direct-stream URL when the server does not transcode',
      () async {
        final client = JellyfinClient(
          config: config,
          httpClient: MockClient((request) async {
            expect(request.url.path, '/Items/item1/PlaybackInfo');
            return http.Response(
              jsonEncode({
                'PlaySessionId': 'session1',
                'MediaSources': [
                  {'Id': 'source1'},
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
