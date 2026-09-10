import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

Map<String, Object?> retainedFixture() => {
  'schemaVersion': 1,
  'state': 'ready',
  'installAvailable': false,
  'installations': [
    {
      'installationId': '1' * 32,
      'installationRevision': 4,
      'installationState': 'container_started',
      'state': 'ready',
      'errorCode': null,
      'bootstrapReceipt': {
        'revision': 7,
        'state': 'ready',
        'serverVersion': '2.8.0',
        'schemaVersion': 29,
        'homeAssistant': {'serviceId': '2' * 32, 'serviceRevision': 3},
        'jellyfin': {'serviceId': '3' * 32, 'serviceRevision': 5},
      },
      'providers': [
        {
          'id': '4' * 32,
          'providerDomain': 'spotify',
          'revision': 2,
          'state': 'ready',
          'updatedAt': '2026-09-10T22:00:00.000Z',
        },
      ],
    },
  ],
};

Map<String, Object?> discoveryFixture() => {
  'inventory': {
    'installationId': '1' * 32,
    'installationRevision': 4,
    'coreRevision': 7,
    'playerRevision': 9,
    'providerRevisions': [
      {'id': '4' * 32, 'providerDomain': 'spotify', 'revision': 2},
    ],
    'targets': [
      {
        'id': 'homepod-living',
        'name': 'Living HomePod',
        'provider': 'universal_player--living',
        'providerDomain': 'universal_player',
        'providerInstanceId': 'universal_player--living',
        'transport': 'airplay',
        'kind': 'device',
        'homePod': true,
        'available': true,
        'enabled': true,
        'playbackState': 'paused',
        'volumeLevel': 32,
        'muted': false,
        'groupMemberIds': <String>[],
        'queueId': 'homepod-living',
        'queue': {
          'id': 'homepod-living',
          'active': true,
          'available': true,
          'itemCount': 4,
          'currentIndex': 1,
          'shuffleEnabled': false,
          'repeatMode': 'off',
          'state': 'paused',
          'nowPlaying': {
            'itemId': 'queue-item-2',
            'title': 'Synthetic Song',
            'durationSeconds': 241,
            'positionSeconds': 37,
          },
        },
        'capabilities': ['play', 'pause', 'queue'],
      },
    ],
    'installAvailable': false,
    'updatedAt': '2026-09-10T22:01:00.000Z',
  },
};

Map<String, Object?> playbackFixture() => {
  'playback': {
    'installationId': '1' * 32,
    'installationRevision': 4,
    'coreRevision': 7,
    'revision': 9,
    'players': <Object?>[],
    'installAvailable': false,
    'updatedAt': '2026-09-10T22:00:30.000Z',
  },
};

void main() {
  test(
    'read resolves exact retained and player revisions before discovery',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint('https://core.fixture'),
        client: MockClient((request) async {
          requests.add(request);
          final response = switch (requests.length) {
            1 => retainedFixture(),
            2 => playbackFixture(),
            _ => discoveryFixture(),
          };
          return http.Response(
            jsonEncode(response),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await ServerCoreMusicTargetsApi(
        transport,
        'a' * 43,
      ).read(isCurrent: () => true);
      expect(requests.map((item) => item.method), ['GET', 'GET', 'POST']);
      expect(
        requests[0].url.path,
        '/api/v1/admin/media/music-assistant/retained',
      );
      expect(
        requests[1].url.path,
        '/api/v1/admin/media/music-assistant/playback/${'1' * 32}',
      );
      expect(
        requests[2].url.path,
        '/api/v1/media/music-assistant/target-discovery',
      );
      expect(jsonDecode(requests[2].body), {
        'installationId': '1' * 32,
        'expectedInstallationRevision': 4,
        'expectedCoreRevision': 7,
        'expectedPlayerRevision': 9,
        'expectedProviderRevisions': [
          {'id': '4' * 32, 'providerDomain': 'spotify', 'revision': 2},
        ],
      });
      expect(result.targets.single.homePod, isTrue);
      expect(result.targets.single.providerDomain, 'universal_player');
      expect(result.targets.single.queue!.nowPlaying!.title, 'Synthetic Song');
      expect(result.targets.single.queue!.positionSeconds, 37);
      expect(result.toString(), isNot(contains('core.fixture')));
      expect(result.toString(), isNot(contains('a' * 43)));
    },
  );

  test(
    'ambiguous retained installations and response drift fail closed',
    () async {
      for (final retained in [
        retainedFixture()
          ..['installations'] = [
            ...(retainedFixture()['installations']! as List),
            ...(retainedFixture()['installations']! as List),
          ],
        retainedFixture()..['token'] = 'private-token',
      ]) {
        final transport = LarenorServerApi(
          endpoint: ServerEndpoint('https://core.fixture'),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(retained),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        await expectLater(
          ServerCoreMusicTargetsApi(
            transport,
            'a' * 43,
          ).read(isCurrent: () => true),
          throwsA(isA<LarenorServerException>()),
        );
      }
    },
  );
}
