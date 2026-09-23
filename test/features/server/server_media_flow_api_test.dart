import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_flow/data/server_media_flow_api.dart';

const requestId = '11111111111111111111111111111111';
const mediaKey = 'movie:tmdb:603';

List<Map<String, Object>> sources() => [
  for (final provider in const [
    'seerr',
    'qbittorrent',
    'sonarr',
    'radarr',
    'jellyfin',
  ])
    {
      'provider': provider,
      'serviceRevision': 7,
      'snapshotRevision': 9,
      'observedAt': 1790132400,
    },
];

Map<String, Object?> flowJson() => {
  'mediaKey': mediaKey,
  'flowRevision': 9,
  'state': 'playable',
  'stages': [
    {
      'name': 'request',
      'state': 'complete',
      'provider': 'seerr',
      'sourceRevision': 7,
    },
    {
      'name': 'download',
      'state': 'complete',
      'provider': 'qbittorrent',
      'sourceRevision': 7,
    },
    {
      'name': 'import',
      'state': 'complete',
      'provider': 'radarr',
      'sourceRevision': 7,
    },
    {
      'name': 'playable',
      'state': 'complete',
      'provider': 'jellyfin',
      'sourceRevision': 7,
    },
  ],
  'sources': sources(),
  'seasons': const [],
  'delivery': const {
    'state': 'hardlink_verified',
    'retryAttempt': 1,
    'fileCount': 1,
  },
};

void main() {
  test('authority handshake precedes one strict secret-free flow read', () async {
    final calls = <http.Request>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls.add(request);
        expect(request.headers['authorization'], 'Bearer synthetic-access');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (request.url.path.endsWith('/authority')) {
          expect(body, {'requestId': requestId, 'mediaKey': mediaKey});
          return http.Response(
            jsonEncode({
              'requestId': requestId,
              'mediaKey': mediaKey,
              'flowRevision': 9,
              'sources': sources(),
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(body, {
          'requestId': requestId,
          'mediaKey': mediaKey,
          'expectedFlowRevision': 9,
          'expectedSources': sources(),
        });
        return http.Response(
          jsonEncode({'requestId': requestId, 'flow': flowJson()}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    final value = await ServerMediaFlowApi(
      api,
      'synthetic-access',
      requestId: () => requestId,
    ).read(mediaKey);

    expect(value.mediaKey, mediaKey);
    expect(value.state, 'playable');
    expect(value.flowRevision, 9);
    expect(value.delivery?.fileCount, 1);
    expect(calls.map((call) => call.url.path), [
      '/api/v1/admin/media/flows/authority',
      '/api/v1/admin/media/flows/read',
    ]);
  });

  test('extra secret-bearing response fields fail closed', () async {
    var calls = 0;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls++;
        if (request.url.path.endsWith('/authority')) {
          return http.Response(
            jsonEncode({
              'requestId': requestId,
              'mediaKey': mediaKey,
              'flowRevision': 9,
              'sources': sources(),
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'requestId': requestId,
            'flow': {...flowJson(), 'accessToken': 'must-not-cross-boundary'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    await expectLater(
      ServerMediaFlowApi(
        api,
        'synthetic-access',
        requestId: () => requestId,
      ).read(mediaKey),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(calls, 2);
  });

  test('authority identity drift prevents the flow read', () async {
    var calls = 0;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({
            'requestId': '22222222222222222222222222222222',
            'mediaKey': mediaKey,
            'flowRevision': 9,
            'sources': sources(),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    await expectLater(
      ServerMediaFlowApi(
        api,
        'synthetic-access',
        requestId: () => requestId,
      ).read(mediaKey),
      throwsA(isA<LarenorServerException>()),
    );
    expect(calls, 1);
  });

  test('invalid media keys fail before network IO', () async {
    var calls = 0;
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 500);
      }),
    );
    addTearDown(api.close);

    await expectLater(
      ServerMediaFlowApi(api, 'synthetic-access').read(
        'https://jellyfin.invalid/item?token=secret',
      ),
      throwsA(isA<LarenorServerException>()),
    );
    expect(calls, 0);
  });
}
