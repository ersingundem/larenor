import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_music_manager_test_support.dart' show musicManagerJson;
import 'server_music_retained_status_test.dart' show retainedJson;

const _token = 'synthetic_loopback_access_token_1234567890';
const _userId = '99999999999999999999999999999999';
const _familyId = '88888888888888888888888888888888';
const _installationId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _refreshId = '11111111111111111111111111111111';
const _searchId = '22222222222222222222222222222222';
const _commandId = '33333333333333333333333333333333';
final _now = DateTime.utc(2026, 9, 23, 12);

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _MusicCore {
  _MusicCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  final paths = <String>[];
  final bodies = <Map<String, dynamic>>[];
  int revision = 6, effects = 0, itemCount = 1;
  String playbackState = 'paused';
  String? currentItemUri = 'spotify://track/current';

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_MusicCore> start() async =>
      _MusicCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Map<String, dynamic> get manager => musicManagerJson(
    revision: revision,
    playbackState: playbackState,
    itemCount: itemCount,
    currentItemUri: currentItemUri,
  );

  Future<void> _serve() async {
    await for (final request in server) {
      paths.add(request.uri.path);
      final bodyText = await utf8.decoder.bind(request).join();
      final body = bodyText.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(bodyText) as Map);
      if (body.isNotEmpty) bodies.add(body);
      if (request.uri.path.endsWith('/auth/logout')) {
        request.response.statusCode = 204;
        await request.response.close();
        continue;
      }
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $_token') {
        await _json(request, {
          'error': {'code': 'invalid_session'},
        }, 401);
        continue;
      }
      switch (request.uri.path) {
        case '/api/v1/auth/me':
          await _json(request, {
            'user': {
              'id': _userId,
              'username': 'operator',
              'role': 'admin',
              'mustChangePassword': false,
            },
          });
        case '/api/v1/context':
          await _json(request, {
            'schemaVersion': 1,
            'coreId': 'a' * 32,
            'homeId': 'b' * 32,
          });
        case '/api/v1/admin/media/music-assistant/retained':
          await _json(request, retainedJson());
        case '/api/v1/admin/media/music-assistant/manager/$_installationId':
          await _json(request, {'manager': manager});
        case '/api/v1/admin/media/music-assistant/manager/refresh':
          expect(body, {
            'requestId': _refreshId,
            'installationId': _installationId,
            'expectedInstallationRevision': 4,
            'expectedCoreRevision': 2,
          });
          await _json(request, {'manager': manager});
        case '/api/v1/admin/media/music-assistant/manager/catalog/search':
          expect(body, {
            'requestId': _searchId,
            'installationId': _installationId,
            'expectedInstallationRevision': 4,
            'expectedCoreRevision': 2,
            'expectedManagerRevision': 6,
            'providerSetupId': 'd' * 32,
            'expectedProviderRevision': 3,
            'providerDomain': 'spotify',
            'providerInstanceId': 'spotify--fixture',
            'query': 'discovery',
            'mediaTypes': const [
              'artist',
              'album',
              'track',
              'playlist',
              'radio',
              'audiobook',
              'podcast',
            ],
            'limit': 25,
            'libraryOnly': false,
          });
          await _json(request, {
            'catalog': {
              'requestId': _searchId,
              'managerRevision': revision,
              'items': const [
                {
                  'uri': 'spotify://track/result',
                  'name': 'Discovery',
                  'mediaType': 'track',
                  'providerInstanceId': 'spotify--fixture',
                  'artists': ['Artist'],
                },
              ],
            },
          });
        case '/api/v1/admin/media/music-assistant/manager/commands':
          expect(body, {
            'requestId': _commandId,
            'installationId': _installationId,
            'expectedInstallationRevision': 4,
            'expectedCoreRevision': 2,
            'expectedPlayerRevision': 6,
            'targetId': 'homepod-living',
            'expectedProvider': 'airplay--main',
            'expectedTargetKind': 'homepod',
            'expectedQueueId': 'homepod-living',
            'expectedGroupMembers': const <String>[],
            'operation': 'queue_replace',
            'mediaUris': const ['spotify://track/result'],
          });
          effects++;
          revision++;
          itemCount = 1;
          currentItemUri = 'spotify://track/result';
          await _json(request, {
            'receipt': {
              'requestId': _commandId,
              'targetId': 'homepod-living',
              'operation': 'queue_replace',
              'state': 'succeeded',
              'playerRevision': revision,
              'code': 'authenticated_readback',
              'installAvailable': false,
            },
          }, 201);
        default:
          await _json(request, {
            'error': {'code': 'not_found'},
          }, 404);
      }
    }
  }

  Future<void> _json(
    HttpRequest request,
    Object value, [
    int status = 200,
  ]) async {
    final encoded = utf8.encode(jsonEncode(value));
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..contentLength = encoded.length
      ..add(encoded);
    await request.response.close();
  }
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test(
    'real Core music path searches Spotify and replaces a HomePod queue',
    () async {
      SharedPreferences.setMockInitialValues({});
      final core = await _MusicCore.start();
      addTearDown(() => core.server.close(force: true));
      final session = ServerSession(
        endpoint: ServerEndpoint(core.baseUrl),
        accessToken: _token,
        refreshToken: 'synthetic_loopback_refresh_token_123456789',
        expiresAt: _now.add(const Duration(hours: 1)),
        user: const ServerUser(
          id: _userId,
          username: 'operator',
          role: ServerRole.admin,
          mustChangePassword: false,
        ),
        sessionFamilyId: _familyId,
      );
      final account = ServerAccountController(
        store: _Store(session),
        clock: () => _now,
        apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
      );
      addTearDown(account.dispose);
      await account.initialize();

      final ids = [_refreshId, _searchId, _commandId].iterator;
      final controller = ServerMusicManagerController(
        account,
        requestId: () {
          if (!ids.moveNext()) throw StateError('request id exhausted');
          return ids.current;
        },
      );
      addTearDown(controller.dispose);
      await controller.load(current: () => true);
      expect(controller.stored, isTrue);
      expect(controller.reachable, isTrue);
      expect(controller.verified, isFalse);

      await controller.verify(current: () => true);
      expect(controller.verified, isTrue);
      expect(controller.selectedProvider?.domain, 'spotify');
      expect(controller.selectedReceiver?.kind, 'homepod');

      await controller.search(' discovery ', current: () => true);
      expect(controller.catalog?.items.single.uri, 'spotify://track/result');
      controller.selectMedia('spotify://track/result');
      await controller.command(
        ServerMusicOperation.queueReplace,
        current: () => true,
      );

      expect(core.effects, 1);
      expect(controller.lastReceipt?.authenticated, isTrue);
      expect(controller.manager?.revision, 7);
      expect(
        controller.selectedQueue?.currentItemUri,
        'spotify://track/result',
      );
      expect(
        core.paths.where(
          (path) =>
              path.contains('/api/websocket') ||
              path.contains('/music_assistant.'),
        ),
        isEmpty,
        reason:
            'the Client must use Larenor Core rather than Home Assistant WS',
      );
      expect(jsonEncode(core.bodies), isNot(contains(_token)));

      await account.signOut();
      expect(controller.manager, isNull);
      expect(controller.catalog, isNull);
      expect(controller.lastReceipt, isNull);
    },
  );
}
