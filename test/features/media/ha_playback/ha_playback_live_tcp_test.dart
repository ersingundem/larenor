import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/media/ha_playback/data/ha_playback_api.dart';
import 'package:larenor/features/media/ha_playback/data/ha_playback_controller.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';

const _token = 'owned-ha-playback-fixture';
const _sourceId = 'media-source://media_source/local/fixture.mp4';

class _OwnedHaPlaybackServer {
  _OwnedHaPlaybackServer._(this.server);
  final HttpServer server;
  final sockets = <WebSocket>[];
  final commands = <Map<String, dynamic>>[];
  int acceptedPlayback = 0;
  int rejected = 0;
  bool playing = false;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_OwnedHaPlaybackServer> start() async {
    final fixture = _OwnedHaPlaybackServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture._handle);
    return fixture;
  }

  Map<String, Object?> get _state => {
    'entity_id': 'media_player.fixture_apple_tv',
    'state': playing ? 'playing' : 'idle',
    'last_updated': playing ? '2026-09-30T10:00:01Z' : '2026-09-30T10:00:00Z',
    'attributes': {
      'friendly_name': 'Fixture Apple TV',
      'supported_features': 512,
      'device_class': 'tv',
      if (playing) 'media_content_id': _sourceId,
    },
  };

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/api/websocket' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      rejected++;
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    socket.add(jsonEncode({'type': 'auth_required', 'ha_version': '2026.9.2'}));
    var authenticated = false;
    socket.listen((raw) {
      final decoded = jsonDecode(raw as String);
      if (decoded is! Map<String, dynamic>) {
        rejected++;
        return;
      }
      if (!authenticated) {
        authenticated =
            decoded['type'] == 'auth' && decoded['access_token'] == _token;
        socket.add(
          jsonEncode({
            'type': authenticated ? 'auth_ok' : 'auth_invalid',
            'ha_version': '2026.9.2',
          }),
        );
        return;
      }
      commands.add(Map<String, dynamic>.from(decoded));
      final id = decoded['id'];
      final type = decoded['type'];
      Object? result;
      var success = true;
      switch (type) {
        case 'subscribe_events':
          success =
              decoded.length == 3 && decoded['event_type'] == 'state_changed';
          result = null;
        case 'get_states':
          success = decoded.length == 2;
          result = [_state];
        case 'get_services':
          success = decoded.length == 2;
          result = {
            'media_player': {
              'play_media': {
                'fields': {
                  'media': {'required': true},
                },
              },
            },
          };
        case 'config/entity_registry/list':
          success = decoded.length == 2;
          result = [
            {
              'entity_id': 'media_player.fixture_apple_tv',
              'id': 'fixture-registry-id',
              'platform': 'apple_tv',
              'device_id': 'fixture-device-id',
              'config_entry_id': 'fixture-config-entry-id',
              'disabled_by': null,
              'hidden_by': null,
            },
          ];
        case 'media_source/browse_media':
          success =
              decoded.length == 2 ||
              (decoded.length == 3 &&
                  decoded['media_content_id'] == 'media-source://');
          result = {
            'media_content_id': 'media-source://',
            'title': 'Sources',
            'media_content_type': 'directory',
            'media_class': 'directory',
            'can_play': false,
            'can_expand': true,
            'children': [
              {
                'media_content_id': _sourceId,
                'title': 'Fixture video',
                'media_content_type': 'video/mp4',
                'media_class': 'video',
                'can_play': true,
                'can_expand': false,
              },
            ],
            'not_shown': 0,
          };
        case 'call_service':
          final expected = {
            'type': 'call_service',
            'domain': 'media_player',
            'service': 'play_media',
            'service_data': {
              'media_content_id': _sourceId,
              'media_content_type': 'video/mp4',
            },
            'target': {'entity_id': 'media_player.fixture_apple_tv'},
            'id': id,
          };
          success = _deepEquals(decoded, expected) && acceptedPlayback == 0;
          if (success) {
            acceptedPlayback++;
            playing = true;
            result = {
              'context': {'id': 'owned-fixture-context'},
            };
          }
        default:
          success = false;
      }
      if (!success) rejected++;
      socket.add(
        jsonEncode({
          'id': id,
          'type': 'result',
          'success': success,
          if (success)
            'result': result
          else
            'error': {
              'code': 'unsupported_fixture_request',
              'message': 'Rejected by owned fixture',
            },
        }),
      );
    });
  }

  static bool _deepEquals(Object? left, Object? right) =>
      jsonEncode(left) == jsonEncode(right);

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
    }
    try {
      await server.close(force: true).timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // The client teardown already closed the owned socket. Never hold the
      // test process open for an OS close notification.
    }
  }
}

void main() {
  test('production Client route uses owned HA TCP, exact Apple TV identity, one request and causal readback', () async {
    final fixture = await _OwnedHaPlaybackServer.start();
    final client = HaWebSocketClient(
      baseUrl: fixture.baseUrl,
      token: _token,
      reconnectDelay: (_) => const Duration(milliseconds: 10),
      heartbeatInterval: Duration.zero,
    )..connect();
    HaPlaybackController? controller;
    StreamSubscription<HaPlaybackSnapshot>? subscription;
    try {
      await client.status
          .firstWhere((status) => status == HaConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      final activeController = HaPlaybackController(
        api: WsHaPlaybackApi(client),
        isCurrent: () => true,
      );
      controller = activeController;
      final snapshots = activeController.changes.asBroadcastStream();
      subscription = snapshots.listen((_) {});
      final ready = await snapshots
          .firstWhere(
            (snapshot) => snapshot.page != null && snapshot.inventory != null,
          )
          .timeout(const Duration(seconds: 5));
      final source = ready.page!.children.single;
      final target = ready.inventory!.targets.single;
      final intent = await activeController.createIntent(source, target);
      expect(intent.transport, HaPlaybackTransport.appleTvVideo);
      final receipt = await activeController.play(intent);
      expect(receipt.status, HaPlaybackReceiptStatus.accepted);
      expect(fixture.acceptedPlayback, 1);
      final observed = await snapshots
          .firstWhere(
            (snapshot) =>
                snapshot.receipt?.status == HaPlaybackReceiptStatus.observed,
          )
          .timeout(const Duration(seconds: 5));
      expect(
        observed.receipt!.target.entityId,
        'media_player.fixture_apple_tv',
      );
      expect(observed.receipt!.source.id, _sourceId);
      expect(fixture.rejected, 0);
      expect(
        fixture.commands.where(
          (command) => command['type'] == 'media_source/resolve_media',
        ),
        isEmpty,
      );
      expect(
        fixture.commands
            .where((command) => command['type'] == 'call_service')
            .single
            .toString(),
        isNot(contains(_token)),
      );
    } finally {
      await subscription?.cancel();
      controller?.dispose();
      client.dispose();
      await fixture.close();
    }
  });
}
