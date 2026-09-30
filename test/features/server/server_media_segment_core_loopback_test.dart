import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/media_segments/data/server_media_segment_api.dart';
import 'package:larenor/features/server/media_segments/domain/server_media_segment_models.dart';

const _token = 'synthetic_segment_access_token_1234567890';
const _requestId = 'aabbccddeeff00112233445566778899';
const _coreId = '1f111111111111111111111111111111';
const _homeId = '2f222222222222222222222222222222';
const _accountId = '3f333333333333333333333333333333';
const _familyId = '4f444444444444444444444444444444';
const _installationId = '5f555555555555555555555555555555';
const _itemId = '6f666666666666666666666666666666';

final class _SegmentCore {
  _SegmentCore._(this.server, {this.wrongFamily = false}) {
    unawaited(_serve());
  }

  final HttpServer server;
  final bool wrongFamily;
  final List<Map<String, dynamic>> bodies = [];
  final List<String?> authorizations = [];

  static Future<_SegmentCore> start({bool wrongFamily = false}) async =>
      _SegmentCore._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        wrongFamily: wrongFamily,
      );

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> _serve() async {
    await for (final request in server) {
      authorizations.add(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      final body = Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(request).join()) as Map,
      );
      bodies.add(body);
      final response = {
        'schemaVersion': 1,
        'requestId': _requestId,
        'authority': {
          'schemaVersion': 1,
          'coreId': _coreId,
          'homeId': _homeId,
          'accountId': _accountId,
          'accountRevision': 7,
          'sessionFamilyId': wrongFamily ? '9' * 32 : _familyId,
          'installationId': _installationId,
          'installationRevision': 3,
          'snapshotRevision': 5,
          'jellyfinServiceRevision': 9,
          'itemId': _itemId,
          'mediaKey': 'movie:tmdb:603',
        },
        'supported': true,
        'reason': 'available',
        'segments': [
          {
            'schemaVersion': 1,
            'kind': 'intro',
            'startSeconds': 10,
            'endSeconds': 75,
          },
          {
            'schemaVersion': 1,
            'kind': 'outro',
            'startSeconds': 7000,
            'endSeconds': 7100,
          },
        ],
      };
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(response));
      await request.response.close();
    }
  }
}

ServerMediaCatalogPage _page() => ServerMediaCatalogPage.fromJson(
  {
    'schemaVersion': 1,
    'installationId': _installationId,
    'installationRevision': 3,
    'snapshotRevision': 5,
    'jellyfinServiceRevision': 9,
    'offset': 0,
    'nextOffset': null,
    'total': 1,
    'items': [
      {
        'itemId': _itemId,
        'mediaKey': 'movie:tmdb:603',
        'title': 'The Matrix',
        'mediaKind': 'movie',
        'runtimeSeconds': 8160,
      },
    ],
  },
  query: 'matrix',
  mediaKind: ServerMediaCatalogKind.movie,
);

ServerSession _session(_SegmentCore core) => ServerSession(
  endpoint: ServerEndpoint(core.baseUrl),
  accessToken: _token,
  refreshToken: 'synthetic_segment_refresh_token_123456789',
  expiresAt: DateTime.utc(2027),
  user: const ServerUser(
    id: _accountId,
    username: 'viewer',
    role: ServerRole.member,
    mustChangePassword: false,
  ),
  sessionFamilyId: _familyId,
  context: ServerContext.fromJson(const {
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': _homeId,
  }),
);

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test(
    'production segment client crosses loopback Core with exact authority',
    () async {
      final core = await _SegmentCore.start();
      addTearDown(() => core.server.close(force: true));
      final session = _session(core);
      final api = LarenorServerApi(endpoint: session.endpoint);
      addTearDown(api.close);
      final page = _page();
      final source = ServerMediaSegmentSource.fromCatalog(
        page,
        page.items.single,
      );

      final result = await ServerMediaSegmentApi(
        api,
        session,
        requestId: () => _requestId,
      ).read(source, sourceEpoch: 11, itemEpoch: 13);

      expect(core.authorizations, ['Bearer $_token']);
      expect(core.bodies.single, {
        'schemaVersion': 1,
        'requestId': _requestId,
        'installationId': _installationId,
        'expectedInstallationRevision': 3,
        'expectedSnapshotRevision': 5,
        'expectedJellyfinServiceRevision': 9,
        'itemId': _itemId,
        'mediaKey': 'movie:tmdb:603',
      });
      expect(result.reason, ServerMediaSegmentReason.available);
      expect(result.segments.map((value) => value.kind), [
        ServerMediaSegmentKind.intro,
        ServerMediaSegmentKind.outro,
      ]);
      expect(result.segmentAt(const Duration(seconds: 74)), isNotNull);
      expect(result.segmentAt(const Duration(seconds: 75)), isNull);
      expect(result.isCurrent(sourceEpoch: 11, itemEpoch: 13), isTrue);
    },
  );

  test(
    'production segment client rejects response from another session family',
    () async {
      final core = await _SegmentCore.start(wrongFamily: true);
      addTearDown(() => core.server.close(force: true));
      final session = _session(core);
      final api = LarenorServerApi(endpoint: session.endpoint);
      addTearDown(api.close);
      final page = _page();
      final source = ServerMediaSegmentSource.fromCatalog(
        page,
        page.items.single,
      );

      await expectLater(
        ServerMediaSegmentApi(
          api,
          session,
          requestId: () => _requestId,
        ).read(source, sourceEpoch: 1, itemEpoch: 1),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    },
  );
}
