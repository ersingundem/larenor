import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/offline_media/data/server_offline_media_api.dart';

const _token = 'synthetic_offline_access_token_1234567890';
const _coreId = '11111111111111111111111111111111';
const _homeId = '22222222222222222222222222222222';
const _accountId = '33333333333333333333333333333333';
const _familyId = '44444444444444444444444444444444';
const _installationId = '55555555555555555555555555555555';
const _itemId = '66666666666666666666666666666666';
const _grantId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _content = utf8.encode('hello');
final _digest = sha256.convert(_content).toString();

final class _OfflineCore {
  _OfflineCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  final List<String> paths = [];
  final List<Map<String, dynamic>> bodies = [];
  final List<String?> authorizations = [];
  int revision = 1;
  int downloaded = 0;
  String state = 'granted';
  late final int expiresAt;

  static Future<_OfflineCore> start() async => _OfflineCore._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  )..expiresAt = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 3600;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Map<String, Object?> get manifest => {
    'schemaVersion': 1,
    'grantId': _grantId,
    'revision': revision,
    'authority': {
      'schemaVersion': 1,
      'coreId': _coreId,
      'homeId': _homeId,
      'accountId': _accountId,
      'accountRevision': 4,
      'sessionFamilyId': _familyId,
      'installationId': _installationId,
      'installationRevision': 3,
      'snapshotRevision': 5,
      'jellyfinServiceRevision': 7,
      'itemId': _itemId,
      'mediaKey': 'movie:tmdb:603',
    },
    'title': 'The Matrix',
    'contentLength': _content.length,
    'contentSha256': _digest,
    'contentType': 'video/mp4',
    'chunkBytes': 16384,
    'downloadedBytes': downloaded,
    'state': state,
    'expiresAt': expiresAt,
  };

  Future<void> _serve() async {
    await for (final request in server) {
      paths.add(request.uri.path);
      authorizations.add(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      final body = Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(request).join()) as Map,
      );
      bodies.add(body);
      if (request.uri.path.endsWith('/chunk')) {
        request.response
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('x-larenor-content-sha256', _digest)
          ..headers.set('x-larenor-chunk-offset', '$downloaded')
          ..contentLength = _content.length
          ..add(_content);
      } else {
        if (request.uri.path.endsWith('/progress')) {
          revision++;
          downloaded = body['downloadedBytes'] as int;
          state = downloaded == _content.length ? 'complete' : 'transferring';
        } else if (request.uri.path.endsWith('/revoke')) {
          revision++;
          state = 'revoked';
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'manifest': manifest}));
      }
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
    'jellyfinServiceRevision': 7,
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

ServerSession _session(_OfflineCore core) => ServerSession(
  endpoint: ServerEndpoint(core.baseUrl),
  accessToken: _token,
  refreshToken: 'synthetic_offline_refresh_token_123456789',
  expiresAt: DateTime.utc(2027),
  user: const ServerUser(
    id: _accountId,
    username: 'traveler',
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
    'production client creates chunks completes and revokes over loopback Core',
    () async {
      final core = await _OfflineCore.start();
      addTearDown(() => core.server.close(force: true));
      final session = _session(core);
      final transport = LarenorServerApi(endpoint: session.endpoint);
      addTearDown(transport.close);
      final requestIds = [
        _grantId,
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'cccccccccccccccccccccccccccccccc',
        'dddddddddddddddddddddddddddddddd',
      ];
      final api = ServerOfflineMediaApi(
        transport,
        session,
        requestId: () => requestIds.removeAt(0),
      );
      final page = _page();

      final granted = await api.create(
        page,
        page.items.single,
        availableBytes: 1000000,
        quotaBytes: 2000000,
      );
      final chunk = await api.chunk(granted);
      final complete = await api.progress(
        granted,
        chunk.length,
        sha256: sha256.convert(chunk).toString(),
      );
      final revoked = await api.revoke(complete);

      expect(chunk, _content);
      expect(granted.state, 'granted');
      expect(complete.complete, isTrue);
      expect(revoked.state, 'revoked');
      expect(core.paths, [
        '/api/v1/media/offline/grants',
        '/api/v1/media/offline/grants/$_grantId/chunk',
        '/api/v1/media/offline/grants/$_grantId/progress',
        '/api/v1/media/offline/grants/$_grantId/revoke',
      ]);
      expect(core.authorizations.toSet(), {'Bearer $_token'});
      expect(core.bodies[0]['installationId'], _installationId);
      expect(core.bodies[0]['itemId'], _itemId);
      expect(core.bodies[0]['storageQuotaBytes'], 2000000);
      expect(core.bodies[1], {
        'schemaVersion': 1,
        'requestId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'expectedRevision': 1,
        'offset': 0,
      });
      expect(core.bodies[2]['contentSha256'], _digest);
      expect(core.bodies[3]['expectedRevision'], 2);
    },
  );
}
