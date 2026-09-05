import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A loopback-only HA protocol fixture, owned by this test process. Writes are
/// rejected except an explicitly enabled synthetic light action. No fallback.
class SyntheticHaServer {
  SyntheticHaServer._(this._server);

  static const token = 'synthetic-e2e-session';
  final HttpServer _server;
  final _sockets = <WebSocket>[];
  final _stateSubscriptions = <WebSocket, int>{};
  bool allowLightActions = false;
  final acceptedActions = <String>[];
  String? _pendingLight;
  final reads = <String>[];
  int rejectedWrites = 0;
  int rejectedLogins = 0;
  int subscriptions = 0;
  int authentications = 0;
  int closedSockets = 0;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  int get port => _server.port;

  static Future<SyntheticHaServer> start() async {
    final fixture = SyntheticHaServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture._server.listen(fixture._handle);
    return fixture;
  }

  static Map<String, Object?> entity(String id, String name, String state) => {
    'entity_id': id,
    'state': state,
    'attributes': {
      'friendly_name': name,
      if (id.startsWith('sensor.')) 'unit_of_measurement': '°C',
    },
    'last_changed': '2026-09-05T08:00:00Z',
    'last_updated': '2026-09-05T08:00:00Z',
    'context': {'id': 'synthetic-context', 'parent_id': null, 'user_id': null},
  };

  final entities = [
    entity('sensor.fixture_temperature', 'Fixture temperature', '21'),
    entity('light.fixture_lamp', 'Fixture lamp', 'off'),
    entity('scene.fixture_evening', 'Fixture evening', 'scening'),
  ];

  static const services = {
    'scene': {
      'turn_on': {'fields': <String, Object?>{}},
    },
    'light': {
      'turn_on': {'fields': <String, Object?>{}},
      'turn_off': {'fields': <String, Object?>{}},
    },
  };

  /// Deliberately separate HTTP acceptance from a subsequent HA state event.
  void observePendingLight() {
    final pending = _pendingLight;
    if (pending == null) throw StateError('No accepted light action');
    _pendingLight = null;
    final index = entities.indexWhere(
      (value) => value['entity_id'] == 'light.fixture_lamp',
    );
    final previous = entities[index];
    final now = DateTime.now().toUtc().toIso8601String();
    final next = {
      ...previous,
      'state': pending,
      'last_changed': now,
      'last_updated': now,
    };
    entities[index] = next;
    for (final entry in _stateSubscriptions.entries) {
      if (entry.key.readyState != WebSocket.open) continue;
      entry.key.add(
        jsonEncode({
          'id': entry.value,
          'type': 'event',
          'event': {
            'event_type': 'state_changed',
            'time_fired': now,
            'data': {
              'entity_id': 'light.fixture_lamp',
              'old_state': previous,
              'new_state': next,
            },
          },
        }),
      );
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/api/websocket' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.add(
        jsonEncode({'type': 'auth_required', 'ha_version': '2026.8.3'}),
      );
      var authenticated = false;
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = message['type'];
        if (!authenticated) {
          authenticated = type == 'auth' && message['access_token'] == token;
          if (authenticated) authentications++;
          socket.add(
            jsonEncode({
              'type': authenticated ? 'auth_ok' : 'auth_invalid',
              'ha_version': '2026.8.3',
            }),
          );
          return;
        }
        final id = message['id'];
        if (type == 'ping') {
          socket.add(jsonEncode({'id': id, 'type': 'pong'}));
          return;
        }
        if (type == 'subscribe_events') {
          subscriptions++;
          if (message['event_type'] == 'state_changed') {
            _stateSubscriptions[socket] = id as int;
          }
        }
        final allowed = {
          'subscribe_events',
          'unsubscribe_events',
          'supported_features',
          'get_states',
          'get_services',
          'get_config',
          'config/area_registry/list',
          'config/entity_registry/list',
          'config/device_registry/list',
        }.contains(type);
        if (!allowed) rejectedWrites++;
        socket.add(
          jsonEncode({
            'id': id,
            'type': 'result',
            'success': allowed,
            if (allowed)
              'result': switch (type) {
                'get_states' => entities,
                'get_services' => services,
                'get_config' => {
                  'time_zone': 'UTC',
                  'location_name': 'Fixture',
                },
                _ => <Object>[],
              }
            else
              'error': {
                'code': 'unauthorized',
                'message': 'Fixture rejects writes',
              },
          }),
        );
      }, onDone: () => closedSockets++);
      return;
    }
    request.response.headers.contentType = ContentType.json;
    if (allowLightActions &&
        request.method == 'POST' &&
        request.headers.value('authorization') == 'Bearer $token' &&
        const {
          '/api/services/light/turn_on',
          '/api/services/light/turn_off',
        }.contains(request.uri.path)) {
      final body = await request.fold<List<int>>(<int>[], (bytes, chunk) {
        if (bytes.length + chunk.length > 1024) {
          throw StateError('Oversized fixture command');
        }
        return bytes..addAll(chunk);
      });
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map &&
          decoded.length == 1 &&
          decoded['entity_id'] == 'light.fixture_lamp') {
        final service = request.uri.pathSegments.last;
        acceptedActions.add('light.$service');
        _pendingLight = service == 'turn_on' ? 'on' : 'off';
        request.response.write('[]');
      } else {
        rejectedWrites++;
        request.response.statusCode = 403;
        request.response.write('{}');
      }
    } else if (request.method != 'GET') {
      rejectedWrites++;
      request.response.statusCode = 403;
      request.response.write('{"message":"Fixture rejects writes"}');
    } else if (request.headers.value('authorization') != 'Bearer $token') {
      rejectedLogins++;
      request.response.statusCode = 401;
      request.response.write('{"message":"Unauthorized"}');
    } else {
      reads.add(request.uri.path);
      final Object? value = switch (request.uri.path) {
        '/api/' => {'message': 'API running.'},
        '/api/states' => entities,
        '/api/config' => {
          'time_zone': 'UTC',
          'location_name': 'Fixture home',
          'version': '2026.8.3',
          'components': <String>[],
        },
        '/api/services' => [
          for (final entry in services.entries)
            {'domain': entry.key, 'services': entry.value},
        ],
        '/api/components' || '/api/events' => <Object>[],
        _ =>
          entities
              .where(
                (entity) =>
                    request.uri.path == '/api/states/${entity['entity_id']}',
              )
              .firstOrNull,
      };
      if (value == null) request.response.statusCode = 404;
      request.response.write(jsonEncode(value ?? {'message': 'Not found'}));
    }
    await request.response.close();
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    await _server.close(force: true);
  }
}

/// All app Dart HTTP/WS traffic must address the fixture's exact loopback port.
/// Unexpected destinations fail before DNS/socket creation, including redirects.
class FixtureNetwork extends HttpOverrides {
  FixtureNetwork(this.port);
  final int port;
  int blocked = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    void check(Uri uri) {
      if (uri.host != '127.0.0.1' || uri.port != port || uri.scheme != 'http') {
        blocked++;
        throw const SocketException('E2E external networking is disabled');
      }
    }

    final client = super.createHttpClient(context);
    // Redirects and proxy sockets are created inside HttpClient, beyond
    // openUrl. Enforce the boundary again at actual connection creation.
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      check(uri);
      if (proxyHost != null || proxyPort != null) {
        blocked++;
        throw const SocketException('E2E proxies are disabled');
      }
      return Socket.startConnect(InternetAddress.loopbackIPv4, port);
    };
    return _FixtureHttpClient(client, check);
  }
}

class _FixtureHttpClient implements HttpClient {
  _FixtureHttpClient(this._inner, this._check);
  final HttpClient _inner;
  final void Function(Uri) _check;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    _check(url);
    return _inner.openUrl(method, url);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  void close({bool force = false}) => _inner.close(force: force);
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set userAgent(String? value) => _inner.userAgent = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set findProxy(String Function(Uri)? value) => _inner.findProxy = value;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unreviewed E2E HTTP client operation');
}
