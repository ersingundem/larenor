import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/casting/domain/remote_playback_models.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';

import 'remote_playback_fixture.dart';

void main() {
  final requests = <http.Request>[];
  JellyfinClient client(http.Response Function(http.Request) response) =>
      JellyfinClient(
        config: const JellyfinConfig(
          baseUrl: 'https://jellyfin.test/prefix',
          userId: userId,
          accessToken: 'fixture-private-token',
          deviceId: 'local-tablet',
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          return response(request);
        }),
      );
  setUp(requests.clear);
  test('session discovery uses authenticated own-user filter and excludes unrelated or incapable receivers', () async {
    final api = client(
      (_) => http.Response(
        jsonEncode([
          targetJson(),
          targetJson(id: 'other', user: otherUserId),
          targetJson(id: 'local', device: 'local-tablet'),
          targetJson(id: 'audio')..['PlayableMediaTypes'] = ['Audio'],
          targetJson(id: 'unsupported')..['SupportsRemoteControl'] = false,
        ]),
        200,
      ),
    );
    addTearDown(api.dispose);
    final targets = await api.getRemoteSessions();
    expect(targets.map((value) => value.sessionId), ['remote-session']);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/prefix/Sessions');
    expect(requests.single.url.queryParameters, {
      'controllableByUserId': userId,
      'activeWithinSeconds': '60',
    });
    expect(
      requests.single.headers['X-Emby-Authorization'],
      contains('Token="fixture-private-token"'),
    );
    expect(
      requests.single.url.toString(),
      isNot(contains('fixture-private-token')),
    );
  });
  test('remote play uses exact query contract and never negotiates or sends local token-bearing stream URLs', () async {
    final api = client((_) => http.Response('', 204));
    addTearDown(api.dispose);
    await api.playOnSession(
      sessionId: 'remote-session',
      itemId: itemId,
      startPosition: const Duration(seconds: 42),
    );
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/prefix/Sessions/remote-session/Playing');
    expect(requests.single.url.queryParameters, {
      'playCommand': 'PlayNow',
      'itemIds': itemId,
      'startPositionTicks': '420000000',
    });
    expect(requests.single.body, isEmpty);
    expect(requests.single.url.toString(), isNot(contains('api_key')));
    expect(
      requests.single.url.toString(),
      isNot(contains('fixture-private-token')),
    );
  });
  test('invalid IDs/position fail before network and non204 success does not fabricate accepted receipt', () async {
    final api = client((_) => http.Response('{}', 200));
    addTearDown(api.dispose);
    await expectLater(
      api.playOnSession(sessionId: '../other', itemId: itemId),
      throwsA(isA<RemotePlaybackException>()),
    );
    await expectLater(
      api.playOnSession(sessionId: 'remote', itemId: 'not-guid'),
      throwsA(isA<RemotePlaybackException>()),
    );
    await expectLater(
      api.playOnSession(
        sessionId: 'remote',
        itemId: itemId,
        startPosition: const Duration(seconds: -1),
      ),
      throwsA(isA<RemotePlaybackException>()),
    );
    expect(requests, isEmpty);
    await expectLater(
      api.playOnSession(sessionId: 'remote', itemId: itemId),
      throwsA(isA<RemotePlaybackException>()),
    );
    expect(requests, hasLength(1));
  });
  for (final status in [401, 403, 500]) {
    test(
      'HTTP$status remains typed and one rejected play is never retried',
      () async {
        final api = client(
          (_) => http.Response('private-backend-details', status),
        );
        addTearDown(api.dispose);
        await expectLater(
          api.playOnSession(sessionId: 'remote', itemId: itemId),
          throwsA(
            isA<MediaApiException>()
                .having((error) => error.statusCode, 'status', status)
                .having(
                  (error) => error.toString(),
                  'redacted',
                  isNot(contains('private-backend-details')),
                ),
          ),
        );
        expect(requests, hasLength(1));
      },
    );
  }
  test('redirected receiver command never forwards authentication to another origin', () async {
    final api = client(
      (_) => http.Response(
        '',
        307,
        headers: {'location': 'https://unrelated.test/capture'},
      ),
    );
    addTearDown(api.dispose);
    await expectLater(
      api.playOnSession(sessionId: 'remote', itemId: itemId),
      throwsA(anything),
    );
    expect(requests, hasLength(1));
    expect(requests.single.followRedirects, isFalse);
  });
}
