import 'dart:convert' show jsonDecode;

import 'package:http/http.dart' as http;

import 'server_admin_test_support.dart';
import 'server_music_retained_status_test.dart' show retainedJson;

Map<String, dynamic> musicManagerJson({
  int revision = 6,
  String playbackState = 'paused',
  double positionSeconds = 5,
  int itemCount = 1,
  String? currentItemUri = 'spotify://track/current',
}) => {
  'installationId': 'a' * 32,
  'installationRevision': 4,
  'coreRevision': 2,
  'revision': revision,
  'providers': [
    {
      'setupId': 'd' * 32,
      'revision': 3,
      'providerDomain': 'spotify',
      'providerInstanceId': 'spotify--fixture',
      'catalogAvailable': true,
    },
  ],
  'queues': [
    {
      'queueId': 'homepod-living',
      'active': playbackState == 'playing',
      'itemCount': itemCount,
      'currentItemUri': currentItemUri,
      'positionSeconds': positionSeconds,
    },
  ],
  'receivers': [
    {
      'playerId': 'homepod-living',
      'name': 'Living room HomePod',
      'provider': 'airplay--main',
      'targetKind': 'homepod',
      'available': true,
      'enabled': true,
      'playbackState': playbackState,
      'volumeLevel': 35,
      'muted': false,
      'groupMembers': <String>[],
      'queueId': 'homepod-living',
      'positionSeconds': positionSeconds,
      'capabilities': ['play', 'pause', 'seek', 'stop', 'queue'],
    },
    {
      'playerId': 'cast-kitchen',
      'name': 'Kitchen Cast',
      'provider': 'chromecast--main',
      'targetKind': 'cast',
      'available': true,
      'enabled': true,
      'playbackState': 'idle',
      'volumeLevel': 25,
      'muted': false,
      'groupMembers': <String>[],
      'queueId': null,
      'positionSeconds': 0.0,
      'capabilities': ['play', 'pause', 'seek'],
    },
    {
      'playerId': 'airplay-office',
      'name': 'Office AirPlay',
      'provider': 'airplay--main',
      'targetKind': 'airplay',
      'available': true,
      'enabled': true,
      'playbackState': 'idle',
      'volumeLevel': 20,
      'muted': false,
      'groupMembers': <String>[],
      'queueId': null,
      'positionSeconds': 0.0,
      'capabilities': ['play', 'pause'],
    },
  ],
  'installAvailable': false,
  'updatedAt': '2026-09-20T10:00:00.000Z',
};

class MusicManagerFixture extends AdminFixture {
  MusicManagerFixture({super.role}) {
    respond = response;
  }

  int revision = 6;
  String playbackState = 'paused';
  double positionSeconds = 5;
  int itemCount = 1;
  String? currentItemUri = 'spotify://track/current';

  Map<String, dynamic> manager() => musicManagerJson(
    revision: revision,
    playbackState: playbackState,
    positionSeconds: positionSeconds,
    itemCount: itemCount,
    currentItemUri: currentItemUri,
  );

  Future<http.Response> response(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/music-assistant/retained')) {
      return json(retainedJson());
    }
    if (request.method == 'GET' &&
        path.endsWith('/music-assistant/manager/${'a' * 32}')) {
      return json({'manager': manager()});
    }
    if (request.method == 'POST' && path.endsWith('/manager/refresh')) {
      return json({'manager': manager()});
    }
    if (request.method == 'POST' && path.endsWith('/manager/catalog/search')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return json({
        'catalog': {
          'requestId': body['requestId'],
          'managerRevision': revision,
          'items': [
            {
              'uri': 'spotify://track/result',
              'name': 'Result track',
              'mediaType': 'track',
              'providerInstanceId': 'spotify--fixture',
              'artists': ['Artist'],
            },
            {
              'uri': 'spotify://radio/result',
              'name': 'Result radio',
              'mediaType': 'radio',
              'providerInstanceId': 'spotify--fixture',
              'artists': <String>[],
            },
          ],
        },
      });
    }
    if (request.method == 'POST' &&
        path.endsWith('/manager/catalog/in-progress')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return json({
        'longform': {
          'requestId': body['requestId'],
          'managerRevision': revision,
          'items': [
            {
              'uri': 'spotify://audiobook/fixture',
              'name': 'Fixture audiobook',
              'mediaType': 'audiobook',
              'providerInstanceId': 'spotify--fixture',
              'durationSeconds': 3600.0,
              'resumePositionSeconds': 900.0,
              'fullyPlayed': false,
              'chapters': [
                {
                  'position': 0,
                  'name': 'Opening',
                  'startSeconds': 0.0,
                  'endSeconds': 1200.0,
                },
              ],
            },
          ],
        },
      });
    }
    if (request.method == 'POST' && path.endsWith('/manager/commands')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      switch (body['operation']) {
        case 'play':
          playbackState = 'playing';
        case 'pause':
          playbackState = 'paused';
        case 'seek':
          positionSeconds = (body['positionSeconds'] as num).toDouble();
        case 'queue_add':
          itemCount++;
        case 'queue_replace':
          final media = body['mediaUris'] as List;
          itemCount = media.length;
          currentItemUri = media.first as String;
        case 'queue_clear':
          itemCount = 0;
          currentItemUri = null;
      }
      revision++;
      return json({
        'receipt': {
          'requestId': body['requestId'],
          'targetId': body['targetId'],
          'operation': body['operation'],
          'state': 'succeeded',
          'playerRevision': revision,
          'code': 'authenticated_readback',
          'installAvailable': false,
        },
      }, 201);
    }
    return defaultResponse(request);
  }
}
