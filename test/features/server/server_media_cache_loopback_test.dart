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
import 'package:larenor/features/server/media_playback/data/server_media_playback_controller.dart';
import 'package:larenor/features/server/media_playback/domain/server_media_playback_models.dart';
import 'package:larenor/features/server/media_result_origin.dart';
import 'package:larenor/features/server/media_rows/data/server_media_rows_cache.dart';
import 'package:larenor/features/server/media_rows/data/server_media_rows_controller.dart';

const _requestId = '11111111111111111111111111111111';
const _installationId = '22222222222222222222222222222222';
const _accountId = '33333333333333333333333333333333';
const _familyId = '44444444444444444444444444444444';
const _intentId = '66666666666666666666666666666666';
const _commandId = '77777777777777777777777777777777';
const _mediaKey = 'movie:tmdb:603';
final _now = DateTime.utc(2026, 9, 23, 8);

final class _SocketHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final socket = await Socket.connect(request.url.host, request.url.port);
    socket.write('${request.method} ${request.url.path} HTTP/1.1\r\n');
    final headers = {
      ...request.headers,
      'host': request.url.authority,
      'connection': 'close',
      'content-length': '${body.length}',
    };
    for (final header in headers.entries) {
      socket.write('${header.key}: ${header.value}\r\n');
    }
    socket.write('\r\n');
    socket.add(body);
    await socket.flush();
    final raw = await socket.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    var split = -1;
    for (var index = 0; index <= raw.length - 4; index++) {
      if (raw[index] == 13 &&
          raw[index + 1] == 10 &&
          raw[index + 2] == 13 &&
          raw[index + 3] == 10) {
        split = index;
        break;
      }
    }
    if (split < 0) throw http.ClientException('fixture closed response');
    final lines = utf8.decode(raw.sublist(0, split)).split('\r\n');
    final responseHeaders = <String, String>{};
    for (final line in lines.skip(1)) {
      final separator = line.indexOf(':');
      if (separator > 0) {
        responseHeaders[line.substring(0, separator).toLowerCase()] = line
            .substring(separator + 1)
            .trim();
      }
    }
    return http.StreamedResponse(
      Stream.value(raw.sublist(split + 4)),
      int.parse(lines.first.split(' ')[1]),
      headers: responseHeaders,
      request: request,
    );
  }
}

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

final class _RowsBackend implements ServerMediaRowsCacheBackend {
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

final class _LoopbackCore {
  _LoopbackCore._(this.server);

  final HttpServer server;
  String coreId = 'a' * 32;
  String homeId = 'b' * 32;
  int catalogSearches = 0, flowReads = 0, playbackEffects = 0, rowReads = 0;
  final bodies = <Map<String, dynamic>>[];
  final paths = <String>[];

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
      paths.add(request.uri.path);
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
      } else if (request.uri.path.endsWith('/auth/me')) {
        result = const {
          'user': {
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
      } else if (request.uri.path.endsWith('/media/rows/target')) {
        result = {
          'schemaVersion': 1,
          'installationId': _installationId,
          'installationRevision': 7,
          'bindingRevision': 12,
        };
      } else if (request.uri.path.endsWith('/media/rows/read')) {
        rowReads++;
        result = {
          'requestId': body['requestId'],
          'installationId': _installationId,
          'installationRevision': 7,
          'bindingRevision': 12,
          'rows': {
            'schemaVersion': 1,
            'revision': 13,
            'recent': const [
              {
                'itemId': '55555555555555555555555555555555',
                'title': 'The Matrix',
                'mediaKind': 'movie',
                'addedAt': 1999999900,
                'runtimeSeconds': 8160,
                'positionSeconds': 0,
              },
            ],
            'resume': const [
              {
                'itemId': '88888888888888888888888888888888',
                'title': 'Severance — S02E01',
                'mediaKind': 'episode',
                'addedAt': 1999999800,
                'runtimeSeconds': 3600,
                'positionSeconds': 900,
              },
            ],
          },
        };
      } else if (request.uri.path.endsWith('/media/catalog/search') ||
          request.uri.path.endsWith('/media/catalog/browse')) {
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
      } else if (request.uri.path.endsWith('/media/playback/intents')) {
        expect(body, {
          'requestId': _intentId,
          'installationId': _installationId,
          'expectedInstallationRevision': 7,
          'expectedSnapshotRevision': 9,
          'expectedJellyfinServiceRevision': 11,
          'itemId': '55555555555555555555555555555555',
          'mediaKey': _mediaKey,
        });
        result = {
          'intent': {
            ...body,
            'playbackRevision': 13,
            'expiresAt': 2000000000,
            'targets': const [
              {
                'targetId': 'living-room',
                'targetRevision': 5,
                'name': 'Living room',
                'available': true,
                'currentItemId': null,
                'positionSeconds': 0,
              },
            ],
          },
        };
      } else if (request.uri.path.endsWith('/media/playback/commands')) {
        expect(body, {
          'requestId': _commandId,
          'intentId': _intentId,
          'expectedPlaybackRevision': 13,
          'targetId': 'living-room',
          'expectedTargetRevision': 5,
          'startSeconds': 0,
        });
        playbackEffects++;
        result = {
          'receipt': {
            'requestId': body['requestId'],
            'intentId': body['intentId'],
            'installationId': _installationId,
            'itemId': '55555555555555555555555555555555',
            'targetId': body['targetId'],
            'playbackRevision': 14,
            'state': 'succeeded',
            'code': 'authenticated_readback',
            'installAvailable': false,
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
  test('real loopback product path browses rows, restarts and retires on Core replacement', () async {
    final core = await _LoopbackCore.start();
    addTearDown(core.close);
    final sessions = _MemorySessions();
    final account = ServerAccountController(
      store: sessions,
      clock: () => _now,
      apiFactory: (endpoint) => LarenorServerApi(
        endpoint: endpoint,
        client: _SocketHttpClient(),
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
    final rowsCache = ServerMediaRowsCache(
      backend: _RowsBackend(),
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
    final oldRows = ServerMediaRowsController(
      account,
      cache: rowsCache,
      requestId: () => _requestId,
    );
    addTearDown(oldCatalog.dispose);
    addTearDown(oldFlow.dispose);
    addTearDown(oldRows.dispose);
    await oldCatalog.searchCurrent(query: 'matrix', current: () => true);
    await oldFlow.load(_mediaKey, current: () => true);
    await oldRows.refresh(current: () => true);
    expect(oldCatalog.origin, ServerMediaResultOrigin.live);
    expect(oldFlow.origin, ServerMediaResultOrigin.live);
    expect(oldRows.origin, ServerMediaResultOrigin.live);
    expect(oldRows.value?.rows.recent.single.title, 'The Matrix');
    expect(oldRows.value?.rows.resume.single.positionSeconds, 900);

    final playbackIds = [_intentId, _commandId].iterator;
    final playback = ServerMediaPlaybackController(
      account,
      requestId: () {
        if (!playbackIds.moveNext()) throw StateError('request id exhausted');
        return playbackIds.current;
      },
    );
    addTearDown(playback.dispose);
    final page = oldCatalog.page!;
    await playback.prepare(page, page.items.single, current: () => true);
    expect(playback.intent?.id, _intentId);
    expect(playback.intent?.targets.single.id, 'living-room');
    await playback.play(playback.intent!.targets.single, current: () => true);
    expect(playback.receipt?.state, ServerMediaPlaybackReceiptState.succeeded);
    expect(core.playbackEffects, 1);

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
    final cachedRows = ServerMediaRowsController(
      account,
      cache: rowsCache,
      requestId: () => _requestId,
    );
    addTearDown(cachedCatalog.dispose);
    addTearDown(cachedFlow.dispose);
    addTearDown(cachedRows.dispose);
    await cachedCatalog.searchCurrent(query: 'matrix', current: () => true);
    await cachedFlow.load(_mediaKey, current: () => true);
    await cachedRows.refresh(current: () => true);
    expect(cachedCatalog.origin, ServerMediaResultOrigin.verifiedCache);
    expect(cachedFlow.origin, ServerMediaResultOrigin.verifiedCache);
    expect(cachedRows.value?.rows.recent.single.title, 'The Matrix');
    expect(cachedRows.value?.rows.resume.single.positionSeconds, 900);
    expect(core.catalogSearches, 1);
    expect(core.flowReads, 1);
    expect(core.rowReads, 2);

    await account.signOut();
    expect(oldCatalog.page, isNull);
    expect(oldFlow.status, isNull);
    expect(playback.intent, isNull);
    expect(playback.receipt, isNull);
    expect(oldRows.value, isNull);
    expect(cachedRows.value, isNull);
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
    final replacementRows = ServerMediaRowsController(
      account,
      cache: rowsCache,
      requestId: () => _requestId,
    );
    addTearDown(replacementCatalog.dispose);
    addTearDown(replacementFlow.dispose);
    addTearDown(replacementRows.dispose);
    await replacementCatalog.searchCurrent(
      query: 'matrix',
      current: () => true,
    );
    await replacementFlow.load(_mediaKey, current: () => true);
    await replacementRows.refresh(current: () => true);

    expect(replacementCatalog.origin, ServerMediaResultOrigin.live);
    expect(replacementFlow.origin, ServerMediaResultOrigin.live);
    expect(replacementRows.origin, ServerMediaResultOrigin.live);
    expect(replacementRows.value?.rows.recent.single.title, 'The Matrix');
    expect(replacementRows.value?.rows.resume.single.positionSeconds, 900);
    expect(core.catalogSearches, 2);
    expect(core.flowReads, 2);
    expect(core.rowReads, 3);
    expect(core.playbackEffects, 1);
    expect(
      core.paths.where((path) => path.contains('jellyfin')).toList(),
      isEmpty,
      reason: 'the Client product path must use only Larenor Core endpoints',
    );
    expect(
      jsonEncode(
        core.bodies.where((body) => body.containsKey('requestId')).toList(),
      ),
      isNot(contains('synthetic password')),
    );
  });

  test('browse recent and resume survive restart then retire on logout and Core switch', () async {
    final core = await _LoopbackCore.start();
    addTearDown(core.close);
    final sessions = _MemorySessions();
    final catalogCache = ServerMediaCatalogCache(
      backend: _CatalogBackend(),
      now: () => _now,
    );
    final rowsCache = ServerMediaRowsCache(
      backend: _RowsBackend(),
      now: () => _now,
    );

    ServerAccountController account() => ServerAccountController(
      store: sessions,
      clock: () => _now,
      apiFactory: (endpoint) => LarenorServerApi(
        endpoint: endpoint,
        client: _SocketHttpClient(),
        clock: () => _now,
      ),
    );

    var currentAccount = account();
    await currentAccount.signIn(
      baseUrl: core.baseUrl,
      username: 'operator',
      password: 'synthetic password',
      deviceName: 'tablet',
    );
    var catalog = ServerMediaCatalogController(
      currentAccount,
      cache: catalogCache,
      requestId: () => _requestId,
    );
    var rows = ServerMediaRowsController(
      currentAccount,
      cache: rowsCache,
      requestId: () => _requestId,
    );
    await catalog.browseCurrent(current: () => true);
    await rows.refresh(current: () => true);
    expect(catalog.page?.items.single.title, 'The Matrix');
    expect(rows.value?.rows.recent.single.title, 'The Matrix');
    expect(rows.value?.rows.resume.single.positionSeconds, 900);

    catalog.dispose();
    rows.dispose();
    currentAccount.dispose();

    currentAccount = account();
    await currentAccount.initialize();
    expect(currentAccount.session?.context?.coreId, 'a' * 32);
    catalog = ServerMediaCatalogController(
      currentAccount,
      cache: catalogCache,
      requestId: () => _requestId,
    );
    rows = ServerMediaRowsController(
      currentAccount,
      cache: rowsCache,
      requestId: () => _requestId,
    );
    await catalog.browseCurrent(current: () => true);
    await rows.refresh(current: () => true);
    expect(catalog.origin, ServerMediaResultOrigin.verifiedCache);
    expect(rows.origin, ServerMediaResultOrigin.live);
    expect(rows.value?.rows.recent.single.title, 'The Matrix');
    expect(rows.value?.rows.resume.single.positionSeconds, 900);
    expect(core.rowReads, 2);

    await currentAccount.signOut();
    expect(catalog.page, isNull);
    expect(rows.value, isNull);
    catalog.dispose();
    rows.dispose();

    core
      ..coreId = 'c' * 32
      ..homeId = 'd' * 32;
    await currentAccount.signIn(
      baseUrl: core.baseUrl,
      username: 'operator',
      password: 'synthetic password',
      deviceName: 'tablet',
    );
    catalog = ServerMediaCatalogController(
      currentAccount,
      cache: catalogCache,
      requestId: () => _requestId,
    );
    rows = ServerMediaRowsController(
      currentAccount,
      cache: rowsCache,
      requestId: () => _requestId,
    );
    addTearDown(() {
      catalog.dispose();
      rows.dispose();
      currentAccount.dispose();
    });
    await catalog.browseCurrent(current: () => true);
    await rows.refresh(current: () => true);
    expect(catalog.origin, ServerMediaResultOrigin.live);
    expect(rows.origin, ServerMediaResultOrigin.live);
    expect(rows.value?.rows.recent.single.title, 'The Matrix');
    expect(rows.value?.rows.resume.single.positionSeconds, 900);
    expect(
      core.paths.where(
        (path) => path.contains('jellyfin') || path.contains('music_assistant'),
      ),
      isEmpty,
    );
  });
}
