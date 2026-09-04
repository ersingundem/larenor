import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/presentation/player/playback_reporter.dart';

const _config = JellyfinConfig(
  baseUrl: 'http://media.test',
  userId: 'user',
  accessToken: 'example',
  deviceId: 'device',
);
const _source = JellyfinPlaybackSource(
  streamUrl: 'http://media.test/video',
  mediaSourceId: 'source',
  playSessionId: 'session',
  isTranscoding: false,
);

void main() {
  test('slow progress is serialized before stop; duplicate stops and late progress are ignored', () async {
    final progress = Completer<http.Response>();
    final paths = <String>[];
    final client = JellyfinClient(
      config: _config,
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/Progress')) return progress.future;
        return http.Response('', 204);
      }),
    );
    addTearDown(client.dispose);
    final reporter = PlaybackReporter(
      client: client,
      itemId: 'movie',
      source: _source,
    );
    await reporter.start(Duration.zero);
    final first = reporter.progress(
      const Duration(seconds: 10),
      isPaused: false,
    );
    await Future<void>.delayed(Duration.zero);
    await reporter.progress(const Duration(seconds: 20), isPaused: false);
    final stopped = reporter.stop(const Duration(seconds: 21));
    final duplicate = reporter.stop(const Duration(seconds: 22));
    expect(identical(stopped, duplicate), isTrue);
    expect(paths, ['/Sessions/Playing', '/Sessions/Playing/Progress']);
    progress.complete(http.Response('', 204));
    await first;
    await stopped;
    await reporter.progress(const Duration(seconds: 30), isPaused: false);
    expect(paths, [
      '/Sessions/Playing',
      '/Sessions/Playing/Progress',
      '/Sessions/Playing/Stopped',
    ]);
  });

  test(
    'reporting failures are best effort and mutations are not retried',
    () async {
      final paths = <String>[];
      final client = JellyfinClient(
        config: _config,
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          throw http.ClientException('offline');
        }),
      );
      addTearDown(client.dispose);
      final reporter = PlaybackReporter(
        client: client,
        itemId: 'movie',
        source: _source,
      );
      await reporter.start(Duration.zero);
      await reporter.start(Duration.zero);
      await reporter.progress(const Duration(seconds: 1), isPaused: false);
      await reporter.stop(const Duration(seconds: 2));
      await reporter.stop(const Duration(seconds: 2));
      expect(paths, [
        '/Sessions/Playing',
        '/Sessions/Playing/Progress',
        '/Sessions/Playing/Stopped',
      ]);
    },
  );
}
