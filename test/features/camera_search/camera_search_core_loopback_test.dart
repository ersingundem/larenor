import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/camera_search/data/camera_search_api.dart';
import 'package:larenor/features/camera_search/domain/camera_search_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _home = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _user = 'cccccccccccccccccccccccccccccccc';
const _camera = 'dddddddddddddddddddddddddddddddd';
const _clip = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _event = 'ffffffffffffffffffffffffffffffff';
const _token = 'loopback_camera_search_access_token_123456';

final class _SearchCore {
  _SearchCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  bool deleted = false;
  bool malformedNextCursor = false;
  Completer<void>? searchEntered, searchBarrier;
  int searches = 0, feedback = 0;
  Map<String, dynamic>? lastFeedback;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_SearchCore> start() async =>
      _SearchCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;

  Future<void> _handle(HttpRequest request) async {
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_token') {
      return _error(request, 401);
    }
    final root = '/api/v1/camera-search/$_core/$_home';
    if (request.method == 'POST' && request.uri.path == '$root/search') {
      searches++;
      final body = await _body(request);
      if (body['schemaVersion'] != 1 ||
          body['query'] != 'red parcel' ||
          body['expectedIndexRevision'] != 7 ||
          body['cameraIds'].toString() != '[$_camera]' ||
          body['pageSize'] != 30) {
        return _error(request, 400);
      }
      if (body['cursor'] == 'tampered.${'x' * 40}') {
        return _error(request, 400);
      }
      searchEntered?.complete();
      await searchBarrier?.future;
      return _json(request, _page());
    }
    if (request.method == 'POST' && request.uri.path == '$root/feedback') {
      feedback++;
      final body = await _body(request);
      lastFeedback = body;
      deleted = true;
      return _json(request, {
        'schemaVersion': 1,
        'requestId': body['requestId'],
        'recorded': true,
      });
    }
    return _error(request, 404);
  }

  Map<String, dynamic> _page() => {
    'schemaVersion': 1,
    'indexRevision': 7,
    'mode': 'local_metadata',
    'status': 'degraded',
    'degradedReason': 'semantic_provider_unavailable',
    'results': deleted
        ? <Object>[]
        : [
            {
              'schemaVersion': 1,
              'startMs': 1788609600000,
              'endMs': 1788609660000,
              'summary': 'A red parcel was left by the door',
              'matchedTerms': ['parcel', 'door'],
              'evidence': {
                'schemaVersion': 1,
                'kind': 'camera_evidence',
                'coreId': _core,
                'homeId': _home,
                'cameraId': _camera,
                'clipId': _clip,
                'eventId': _event,
                'captureRevision': 4,
                'indexRevision': 7,
                'capturedAtMs': 1788609610000,
              },
            },
          ],
    'nextCursor': malformedNextCursor ? 'bad' : null,
  };

  Future<void> close() => server.close(force: true);
}

void _json(HttpRequest request, Object value, [int status = 200]) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(value));
  unawaited(request.response.close());
}

void _error(HttpRequest request, int status) => _json(request, {
  'error': {'code': 'invalid_request'},
}, status);

ServerSession _session(String baseUrl) => ServerSession(
  endpoint: ServerEndpoint(baseUrl),
  accessToken: _token,
  refreshToken: 'loopback_camera_search_refresh_token_12345',
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
  }),
  user: const ServerUser(
    id: _user,
    username: 'member',
    role: ServerRole.member,
    mustChangePassword: false,
  ),
);

CameraSearchFilter _filter() => CameraSearchFilter(
  expectedIndexRevision: 7,
  start: DateTime.utc(2026, 9, 5, 12),
  end: DateTime.utc(2026, 9, 5, 13),
  cameraIds: const [_camera],
);

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('production client crosses loopback Core for search, correction, deletion, and malformed cursor', () async {
    final core = await _SearchCore.start();
    addTearDown(core.close);
    final transport = LarenorServerApi(endpoint: ServerEndpoint(core.baseUrl));
    addTearDown(transport.close);
    final api = CameraSearchApi(
      transport,
      _session(core.baseUrl),
      isCurrent: () => true,
    );

    final first = await api.search(query: 'red parcel', filter: _filter());
    expect(first.results.single.evidence.clipId, _clip);
    await api.reportIncorrect(
      query: 'red parcel',
      expectedIndexRevision: 7,
      evidence: first.results.single.evidence,
      reason: CameraSearchFeedbackReason.wrongSummary,
    );
    expect(core.feedback, 1);
    expect(core.lastFeedback?['reason'], 'wrong_summary');
    expect((core.lastFeedback?['requestId'] as String), hasLength(32));

    final afterCorrection = await api.search(
      query: 'red parcel',
      filter: _filter(),
    );
    expect(afterCorrection.results, isEmpty);

    await expectLater(
      api.search(
        query: 'red parcel',
        filter: _filter(),
        cursor: 'tampered.${'x' * 40}',
      ),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_request',
        ),
      ),
    );

    core.malformedNextCursor = true;
    await expectLater(
      api.search(
        query: 'red parcel',
        filter: _filter(),
        cursor: 'cursor.${'x' * 40}',
      ),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(core.searches, 4);
  });

  test('late authority invalidation cancels a real in-flight search', () async {
    final core = await _SearchCore.start();
    addTearDown(core.close);
    final transport = LarenorServerApi(endpoint: ServerEndpoint(core.baseUrl));
    addTearDown(transport.close);
    var current = true;
    core.searchEntered = Completer<void>();
    core.searchBarrier = Completer<void>();
    final api = CameraSearchApi(
      transport,
      _session(core.baseUrl),
      isCurrent: () => current,
    );

    final pending = api.search(query: 'red parcel', filter: _filter());
    await core.searchEntered!.future;
    current = false;
    core.searchBarrier!.complete();
    await expectLater(
      pending,
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    expect(core.searches, 1);
  });
}
