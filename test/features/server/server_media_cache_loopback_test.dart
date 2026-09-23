import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_cache.dart';
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_controller.dart';
import 'package:larenor/features/server/media_flow/data/server_media_flow_cache.dart';
import 'package:larenor/features/server/media_flow/data/server_media_flow_controller.dart';
import 'package:larenor/features/server/media_flow/domain/server_media_flow_models.dart';
import 'package:larenor/features/server/media_result_origin.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';
const _accountId = '33333333333333333333333333333333';
const _familyId = '44444444444444444444444444444444';
const _mediaKey = 'movie:tmdb:603';
final _now = DateTime.utc(2026, 9, 23, 8);

final class _MemorySessions implements ServerSessionPersistence {
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _CatalogBackend implements ServerMediaCatalogCacheBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    value = null;
    return true;
  }

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    if (!current() || value != expected) return false;
    value = next;
    if (!current()) {
      await compareAndClear(next);
      return false;
    }
    return true;
  }
}

final class _FlowBackend implements ServerMediaFlowCacheBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    value = null;
    return true;
  }

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    if (!current() || value != expected) return false;
    value = next;
    if (!current()) {
      await compareAndClear(next);
      return false;
    }
    return true;
  }

  @override
  Future<void> clear() async => value = null;

  @override
  Future<void> write(String value) async => this.value = value;
}

final class _LoopbackCore {
  _LoopbackCore._(this.server);

  final HttpServer server;
  String coreId = 'a' * 32;
  String homeId = 'b' * 32;
  int catalogSearches = 0, flowReads = 0;
  final bodies = <Map<String, dynamic>>[];

  static Future<_LoopbackCore> start() async {
    final value = _LoopbackCore._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    unawaited(value._serve());
    return value;
  }

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  List<Map<String, Object>> get sources => [
    for (final provider in serverMediaFlowProviderOrder)
      {
        'provider': provider,
        'serviceRevision': 7,
        'snapshotRevision': 9,
        'observedAt': _now.millisecondsSinceEpoch ~/ 1000 - 60,
      },
  ];

  Future<void> _serve() async {
    await for (final request in server) {
      final bodyText = await utf8.decoder.bind(request).join();
      final body = bodyText.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(bodyText) as Map);
      if (body.isNotEmpty) bodies.add(body);
      Object? result;
      var status = 200;
      if (request.uri.path.endsWith('/auth/login')) {
        result = {
          'accessToken': 'a' * 43,
          'refreshToken': 'b' * 43,
          'expiresIn': 3600,
          'sessionFamilyId': _familyId,
          'user': const {
            'id': _accountId,
            'username': 'operator',
            'role': 'admin',
            'mustChangePassword': false,
          },
        };
      } else if (request.uri.path.endsWith('/auth/logout')) {
        status = 204;
      } else if (request.uri.path.endsWith('/context')) {
        result = {'schemaVersion': 1, 'coreId': coreId, 'homeId': homeId};
      } else if (request.uri.path.endsWith('/media/catalog/target')) {
        result = {
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'snapshotRevision': 9,
          'jellyfinServiceRevision': 11,
        };
      } else if (request.uri.path.endsWith('/media/catalog/search')) {
        catalogSearches++;
        result = {
          'requestId': body['requestId'],
          'catalog': {
            'schemaVersion': 1,
            'installationId': _installationId,
            'installationRevision': 7,
            'snapshotRevision': 9,
            'jellyfinServiceRevision': 11,
            'offset': 0,
            'nextOffset': null,
            'total': 1,
            'items': const [
              {
                'itemId': '55555555555555555555555555555555',
                'mediaKey': _mediaKey,
                'title': 'The Matrix',
                'mediaKind': 'movie',
                'runtimeSeconds': 8160,
              },
            ],
          },
        };
      } else if (request.uri.path.endsWith('/media/flows/authority')) {
        result = {
          'requestId': body['requestId'],
          'mediaKey': _mediaKey,
          'flowRevision': 9,
          'sources': sources,
        };
      } else if (request.uri.path.endsWith('/media/flows/read')) {
        flowReads++;
        result = {
          'requestId': body['requestId'],
          'flow': {
            'mediaKey': _mediaKey,
            'flowRevision': 9,
            'state': 'playable',
            'stages': const [
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
            'sources': sources,
            'seasons': const [],
            'delivery': const {
              'state': 'hardlink_verified',
              'retryAttempt': 1,
              'fileCount': 1,
            },
          },
        };
      } else {
        status = 404;
        result = {
          'error': {'code': 'not_found'},
        };
      }
      request.response.statusCode = status;
      if (result != null) {
        final encoded = utf8.encode(jsonEncode(result));
        request.response.headers.contentType = ContentType.json;
        request.response.contentLength = encoded.length;
        request.response.add(encoded);
      }
      await request.response.close();
    }
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  test('real loopback cache retires on logout and misses a same-URL Core replacement', () async {
    final core = await _LoopbackCore.start();
    addTearDown(core.close);
    final sessions = _MemorySessions();
    final account = ServerAccountController(
      store: sessions,
      clock: () => _now,
      apiFactory: (endpoint) => LarenorServerApi(
        endpoint: endpoint,
        client: http.Client(),
        clock: () => _now,
      ),
    );
    addTearDown(account.dispose);
    final catalogCache = ServerMediaCatalogCache(
      backend: _CatalogBackend(),
      now: () => _now,
    );
    final flowCache = ServerMediaFlowCache(
      backend: _FlowBackend(),
      now: () => _now,
    );

    await account.signIn(
      baseUrl: core.baseUrl,
      username: 'operator',
      password: 'synthetic password',
      deviceName: 'tablet',
    );
    final oldCatalog = ServerMediaCatalogController(
      account,
      cache: catalogCache,
      requestId: () => _requestId,
    );
    final oldFlow = ServerMediaFlowController(
      account,
      cache: flowCache,
      requestId: () => _requestId,
    );
    addTearDown(oldCatalog.dispose);
    addTearDown(oldFlow.dispose);
    await oldCatalog.searchCurrent(query: 'matrix', current: () => true);
    await oldFlow.load(_mediaKey, current: () => true);
    expect(oldCatalog.origin, ServerMediaResultOrigin.live);
    expect(oldFlow.origin, ServerMediaResultOrigin.live);

    final cachedCatalog = ServerMediaCatalogController(
      account,
      cache: catalogCache,
      requestId: () => _requestId,
    );
    final cachedFlow = ServerMediaFlowController(
      account,
      cache: flowCache,
      requestId: () => _requestId,
    );
    addTearDown(cachedCatalog.dispose);
    addTearDown(cachedFlow.dispose);
    await cachedCatalog.searchCurrent(query: 'matrix', current: () => true);
    await cachedFlow.load(_mediaKey, current: () => true);
    expect(cachedCatalog.origin, ServerMediaResultOrigin.verifiedCache);
    expect(cachedFlow.origin, ServerMediaResultOrigin.verifiedCache);
    expect(core.catalogSearches, 1);
    expect(core.flowReads, 1);

    await account.signOut();
    expect(oldCatalog.page, isNull);
    expect(oldFlow.status, isNull);
    core
      ..coreId = 'c' * 32
      ..homeId = 'd' * 32;
    await account.signIn(
      baseUrl: core.baseUrl,
      username: 'operator',
      password: 'synthetic password',
      deviceName: 'tablet',
    );
    final replacementCatalog = ServerMediaCatalogController(
      account,
      cache: catalogCache,
      requestId: () => _requestId,
    );
    final replacementFlow = ServerMediaFlowController(
      account,
      cache: flowCache,
      requestId: () => _requestId,
    );
    addTearDown(replacementCatalog.dispose);
    addTearDown(replacementFlow.dispose);
    await replacementCatalog.searchCurrent(
      query: 'matrix',
      current: () => true,
    );
    await replacementFlow.load(_mediaKey, current: () => true);

    expect(replacementCatalog.origin, ServerMediaResultOrigin.live);
    expect(replacementFlow.origin, ServerMediaResultOrigin.live);
    expect(core.catalogSearches, 2);
    expect(core.flowReads, 2);
    expect(jsonEncode(core.bodies), isNot(contains('synthetic password')));
  });
}
