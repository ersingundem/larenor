import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/media_playback/data/server_media_playback_api.dart';
import 'package:larenor/features/server/media_playback/domain/server_media_playback_models.dart';

const _token = 'synthetic_loopback_access_token_1234567890';
const _userId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _installationId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _itemId = 'cccccccccccccccccccccccccccccccc';
const _intentId = 'dddddddddddddddddddddddddddddddd';
const _commandId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

final class _Store implements ServerSessionPersistence {
  _Store(this.value);

  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _PlaybackCore {
  _PlaybackCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  int effects = 0;
  Map<String, Object?>? receipt;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_PlaybackCore> start() async =>
      _PlaybackCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

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
      return _json(request, {
        'error': {'code': 'invalid_session'},
      }, 401);
    }
    switch (request.uri.path) {
      case '/api/v1/auth/me':
        return _json(request, {
          'user': {
            'id': _userId,
            'username': 'loopback',
            'role': 'member',
            'mustChangePassword': false,
          },
        });
      case '/api/v1/context':
        return _json(request, {
          'schemaVersion': 1,
          'coreId': '1' * 32,
          'homeId': '2' * 32,
        });
      case '/api/v1/media/playback/intents':
        final body = await _body(request);
        expect(body, {
          'requestId': _intentId,
          'installationId': _installationId,
          'expectedInstallationRevision': 7,
          'expectedSnapshotRevision': 9,
          'expectedJellyfinServiceRevision': 11,
          'itemId': _itemId,
          'mediaKey': 'movie:tmdb:603',
        });
        return _json(request, {
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
        });
      case '/api/v1/media/playback/commands':
        final body = await _body(request);
        expect(body, {
          'requestId': _commandId,
          'intentId': _intentId,
          'expectedPlaybackRevision': 13,
          'targetId': 'living-room',
          'expectedTargetRevision': 5,
          'startSeconds': 0,
        });
        receipt ??= {
          'requestId': _commandId,
          'intentId': _intentId,
          'installationId': _installationId,
          'itemId': _itemId,
          'targetId': 'living-room',
          'playbackRevision': 14,
          'state': 'succeeded',
          'code': 'authenticated_readback',
          'installAvailable': false,
        };
        if (effects == 0) effects++;
        return _json(request, {'receipt': receipt}, 201);
      default:
        return _json(request, {
          'error': {'code': 'not_found'},
        }, 404);
    }
  }

  void _json(HttpRequest request, Object value, [int status = 200]) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(value))
      ..close();
  }
}

Map<String, Object?> _pageJson() => {
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
      'itemId': _itemId,
      'mediaKey': 'movie:tmdb:603',
      'title': 'The Matrix',
      'mediaKind': 'movie',
      'runtimeSeconds': 8160,
    },
  ],
};

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test('intent command and replay cross real loopback Core HTTP', () async {
    final core = await _PlaybackCore.start();
    addTearDown(() => core.server.close(force: true));
    final now = DateTime.utc(2026, 9, 23, 12);
    final session = ServerSession(
      endpoint: ServerEndpoint(core.baseUrl),
      accessToken: _token,
      refreshToken: 'synthetic_loopback_refresh_token_123456789',
      expiresAt: now.add(const Duration(hours: 1)),
      user: const ServerUser(
        id: _userId,
        username: 'loopback',
        role: ServerRole.member,
        mustChangePassword: false,
      ),
    );
    final account = ServerAccountController(
      store: _Store(session),
      clock: () => now,
      apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
    );
    addTearDown(account.dispose);
    await account.initialize();
    final page = ServerMediaCatalogPage.fromJson(
      _pageJson(),
      query: 'matrix',
      mediaKind: ServerMediaCatalogKind.movie,
    );
    late ServerMediaPlaybackIntent intent;
    late ServerMediaPlaybackReceipt first, replay;
    await account.withSession((api, current) async {
      final client = ServerMediaPlaybackApi(
        api,
        current.accessToken,
        requestId: () => _intentId,
        now: () => now,
      );
      intent = await client.prepare(page, page.items.single);
      final command = ServerMediaPlaybackApi(
        api,
        current.accessToken,
        requestId: () => _commandId,
        now: () => now,
      );
      first = await command.play(intent, intent.targets.single);
      replay = await command.play(intent, intent.targets.single);
    });

    expect(first.state, ServerMediaPlaybackReceiptState.succeeded);
    expect(replay.requestId, first.requestId);
    expect(replay.playbackRevision, first.playbackRevision);
    expect(core.effects, 1);
  });
}
