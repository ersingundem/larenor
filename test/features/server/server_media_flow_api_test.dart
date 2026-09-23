import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_flow/data/server_media_flow_api.dart';
import 'package:larenor/features/server/media_flow/data/server_media_flow_controller.dart';
import 'package:larenor/features/server/media_flow/domain/server_media_flow_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_admin_test_support.dart';

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

final class _FlowFixture extends AdminFixture {
  _FlowFixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/authority')) {
        if (unauthorized) {
          return this.json({
            'error': {'code': 'unauthorized'},
          }, 401);
        }
        return this.json({
          'requestId': requestId,
          'mediaKey': mediaKey,
          'flowRevision': 9,
          'sources': sources(),
        });
      }
      if (request.url.path.endsWith('/read')) {
        return pending?.future ??
            this.json({'requestId': requestId, 'flow': flowJson()});
      }
      return defaultResponse(request);
    };
  }

  bool unauthorized = false;
  Completer<http.Response>? pending;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'authority handshake precedes one strict secret-free flow read',
    () async {
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
    },
  );

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

  test(
    'flow model rejects reordered, mismatched and contradictory evidence',
    () {
      final secret = {...flowJson(), 'accessToken': 'must-not-cross-boundary'};
      final reordered = flowJson();
      (reordered['sources'] as List).setAll(
        0,
        (reordered['sources'] as List).reversed,
      );
      final wrongStage = flowJson();
      (wrongStage['stages'] as List)[2] = {
        ...(wrongStage['stages'] as List)[2] as Map<String, Object>,
        'provider': 'sonarr',
      };
      final contradictory = {...flowJson(), 'state': 'downloading'};
      for (final value in [secret, reordered, wrongStage, contradictory]) {
        expect(
          () => ServerMediaFlowStatus.fromJson(value),
          throwsFormatException,
        );
      }
    },
  );

  test('series coverage remains bounded and internally coherent', () {
    final flow = flowJson();
    flow
      ..['mediaKey'] = 'series:tvdb:81189'
      ..['state'] = 'partial'
      ..['stages'] = [
        (flow['stages'] as List)[0],
        (flow['stages'] as List)[1],
        {
          ...(flow['stages'] as List)[2] as Map<String, Object>,
          'provider': 'sonarr',
        },
        {
          ...(flow['stages'] as List)[3] as Map<String, Object>,
          'state': 'partial',
        },
      ]
      ..['seasons'] = const [
        {
          'seasonNumber': 1,
          'knownEpisodes': [1, 2],
          'downloadedEpisodes': [1, 2],
          'importedEpisodes': [1],
          'playableEpisodes': [1],
          'missingEpisodes': [2],
          'requested': true,
          'requestable': false,
          'incomplete': true,
          'missingSeason': false,
          'partialImport': true,
        },
      ];

    final value = ServerMediaFlowStatus.fromJson(flow);
    expect(value.state, 'partial');
    expect(value.seasons.single.missingEpisodes, [2]);

    final forged = flowJson()
      ..['mediaKey'] = 'series:tvdb:81189'
      ..['state'] = 'partial'
      ..['stages'] = flow['stages']
      ..['seasons'] = [
        {
          ...(flow['seasons'] as List).single as Map<String, Object>,
          'missingEpisodes': <int>[],
        },
      ];
    expect(() => ServerMediaFlowStatus.fromJson(forged), throwsFormatException);
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
      ServerMediaFlowApi(
        api,
        'synthetic-access',
      ).read('https://jellyfin.invalid/item?token=secret'),
      throwsA(isA<LarenorServerException>()),
    );
    expect(calls, 0);
  });

  test('account loss retires an in-flight central flow read', () async {
    final fixture = _FlowFixture()..pending = Completer<http.Response>();
    await fixture.account.initialize();
    final controller = ServerMediaFlowController(
      fixture.account,
      requestId: () => requestId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);

    final pending = controller.load(mediaKey, current: () => true);
    await Future<void>.delayed(Duration.zero);
    await fixture.account.signOut();
    fixture.pending!.complete(
      fixture.json({'requestId': requestId, 'flow': flowJson()}),
    );
    await pending;

    expect(controller.status, isNull);
    expect(controller.busy, false);
  });

  test('active unauthorized retires the exact account session', () async {
    final fixture = _FlowFixture()..unauthorized = true;
    await fixture.account.initialize();
    final controller = ServerMediaFlowController(
      fixture.account,
      requestId: () => requestId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);

    await controller.load(mediaKey, current: () => true);

    expect(controller.status, isNull);
    expect(fixture.account.session, isNull);
    expect(fixture.account.failure, 'unauthorized');
  });
}
