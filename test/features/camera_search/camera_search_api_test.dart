import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/camera_search/data/camera_search_api.dart';
import 'package:larenor/features/camera_search/domain/camera_search_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

ServerContext context() => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});

ServerSession session() => ServerSession(
  endpoint: ServerEndpoint('https://core.invalid'),
  accessToken: 'x' * 43,
  refreshToken: 'y' * 43,
  expiresAt: DateTime.utc(2026, 10),
  context: context(),
  user: ServerUser(
    id: 'c' * 32,
    username: 'member',
    role: ServerRole.member,
    mustChangePassword: false,
  ),
);

Map<String, Object?> pageJson({String? homeId, bool secret = false}) => {
  'schemaVersion': 1,
  'indexRevision': 7,
  'mode': 'local_metadata',
  'status': 'degraded',
  'degradedReason': 'semantic_provider_unavailable',
  'results': [
    {
      'schemaVersion': 1,
      'startMs': 1788609600000,
      'endMs': 1788609660000,
      'summary': 'A red parcel was left by the door',
      'matchedTerms': ['parcel', 'door'],
      'evidence': {
        'schemaVersion': 1,
        'kind': 'camera_evidence',
        'coreId': 'a' * 32,
        'homeId': homeId ?? 'b' * 32,
        'cameraId': 'd' * 32,
        'clipId': 'e' * 32,
        'eventId': 'f' * 32,
        'captureRevision': 4,
        'indexRevision': 7,
        'capturedAtMs': 1788609610000,
      },
      if (secret) 'rawClipUrl': 'https://camera.invalid/token',
    },
  ],
  'nextCursor': null,
};

void main() {
  test('search sends an exact bounded request and parses scoped evidence', () async {
    late http.Request request;
    final transport = LarenorServerApi(
      endpoint: session().endpoint,
      client: MockClient((value) async {
        request = value;
        return http.Response(
          jsonEncode(pageJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(transport.close);
    final api = CameraSearchApi(transport, session(), isCurrent: () => true);
    final page = await api.search(
      query: 'red parcel',
      filter: CameraSearchFilter(
        expectedIndexRevision: 7,
        start: DateTime.utc(2026, 9, 5, 12),
        end: DateTime.utc(2026, 9, 5, 13),
        cameraIds: ['d' * 32],
      ),
    );
    expect(page.results.single.evidence.cameraId, 'd' * 32);
    expect(request.method, 'POST');
    expect(request.url.path, '/camera-search/${'a' * 32}/${'b' * 32}/search');
    expect(jsonDecode(request.body), {
      'schemaVersion': 1,
      'query': 'red parcel',
      'expectedIndexRevision': 7,
      'startMs': 1788609600000,
      'endMs': 1788613200000,
      'cameraIds': ['d' * 32],
      'pageSize': 30,
      'cursor': null,
    });
  });

  test('foreign scope and secret-bearing results fail closed', () {
    for (final body in [
      pageJson(homeId: '0' * 32),
      pageJson(secret: true),
    ]) {
      expect(
        () => CameraSearchPage.fromJson(body, context()),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });
}
