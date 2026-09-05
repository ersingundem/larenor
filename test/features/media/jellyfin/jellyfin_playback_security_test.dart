import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';

void main() {
  JellyfinClient clientFor({
    String? streamPath,
    String sourceId = 'source',
    String token = 'token',
  }) {
    final client = JellyfinClient(
      config: JellyfinConfig(
        baseUrl: 'https://media.example.test/jellyfin/',
        userId: 'user',
        accessToken: token,
        deviceId: 'device',
      ),
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'PlaySessionId': 'session',
            'MediaSources': [
              {
                'Id': sourceId,
                'TranscodingUrl': ?streamPath,
                'SupportsDirectPlay': streamPath == null,
                'SupportsTranscoding': streamPath != null,
              },
            ],
          }),
          200,
        ),
      ),
    );
    addTearDown(client.dispose);
    return client;
  }

  for (final path in [
    'https://untrusted.test/video?api_key=private',
    '//untrusted.test/video?api_key=private',
    'http://media.example.test/jellyfin/video',
    'https://media.example.test:8443/jellyfin/video',
    'https://private@media.example.test/jellyfin/video',
    'https://media.example.test/another/video',
    '../another/video',
    '/jellyfin/%2e%2e/another/video',
    '/video#fragment',
    'file:///private/video',
  ]) {
    test('rejects untrusted playback URL: $path', () async {
      await expectLater(
        clientFor(streamPath: path).getPlaybackInfo('item'),
        throwsA(isA<MediaApiException>()),
      );
    });
  }

  for (final path in [
    '/Videos/item/master.m3u8?api_key=key',
    '/jellyfin/Videos/item/master.m3u8?api_key=key',
    'Videos/item/master.m3u8?api_key=key',
    'https://media.example.test/jellyfin/Videos/item/master.m3u8?api_key=key',
  ]) {
    test('preserves same-server playback and proxy prefix: $path', () async {
      final playback = await clientFor(streamPath: path)
          .getPlaybackInfo('item');
      expect(
        playback.streamUrl,
        'https://media.example.test/jellyfin/Videos/item/master.m3u8?api_key=key',
      );
    });
  }

  test(
    'encodes opaque stream IDs and tokens as separate query values',
    () async {
      final playback = await clientFor(
        sourceId: 'source&api_key=wrong',
        token: 'token&injected=true',
      ).getPlaybackInfo('item/with?symbols');
      final uri = Uri.parse(playback.streamUrl);
      expect(uri.pathSegments, [
        'jellyfin',
        'Videos',
        'item/with?symbols',
        'stream',
      ]);
      expect(uri.queryParameters, {
        'static': 'true',
        'mediaSourceId': 'source&api_key=wrong',
        'api_key': 'token&injected=true',
      });
    },
  );

  test('image tags cannot inject URL query parameters', () {
    final url = clientFor().imageUrl('item', tag: 'tag&api_key=injected');
    expect(Uri.parse(url).queryParameters, {'tag': 'tag&api_key=injected'});
  });
}
