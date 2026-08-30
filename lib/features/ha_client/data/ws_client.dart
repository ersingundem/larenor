import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'models/ha_entity.dart';

enum HaConnectionStatus { connecting, connected, disconnected }

/// Thin wrapper over Home Assistant's WebSocket API (`/api/websocket`).
///
/// Handles the auth handshake, subscribes to `state_changed` events, and
/// reconnects with exponential backoff on disconnect.
/// See https://developers.home-assistant.io/docs/api/websocket/
class HaWebSocketClient {
  HaWebSocketClient({required String baseUrl, required this.token})
    : _wsUrl = _toWsUrl(baseUrl);

  final String _wsUrl;
  final String token;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  int _messageId = 1;
  bool _disposed = false;
  int _retryAttempt = 0;

  final _entityController = StreamController<HaEntity>.broadcast();
  final _statusController = StreamController<HaConnectionStatus>.broadcast();

  Stream<HaEntity> get entityUpdates => _entityController.stream;
  Stream<HaConnectionStatus> get status => _statusController.stream;

  static String _toWsUrl(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri.replace(scheme: scheme, path: '/api/websocket').toString();
  }

  void connect() {
    if (_disposed) return;
    _statusController.add(HaConnectionStatus.connecting);

    final channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
    _channel = channel;

    _subscription = channel.stream.listen(
      _onMessage,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );
  }

  void _onMessage(dynamic raw) {
    final message = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (message['type']) {
      case 'auth_required':
        _send({'type': 'auth', 'access_token': token});
      case 'auth_ok':
        _retryAttempt = 0;
        _statusController.add(HaConnectionStatus.connected);
        _send({
          'id': _messageId++,
          'type': 'subscribe_events',
          'event_type': 'state_changed',
        });
      case 'auth_invalid':
        _statusController.add(HaConnectionStatus.disconnected);
        _channel?.sink.close();
      case 'event':
        _handleEvent(message);
    }
  }

  void _handleEvent(Map<String, dynamic> message) {
    final event = message['event'] as Map<String, dynamic>?;
    if (event == null || event['event_type'] != 'state_changed') return;

    final data = event['data'] as Map<String, dynamic>;
    final newState = data['new_state'] as Map<String, dynamic>?;
    if (newState == null) return;

    _entityController.add(HaEntity.fromJson(newState));
  }

  void _send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void _scheduleReconnect() {
    _subscription?.cancel();
    if (_disposed) return;

    _statusController.add(HaConnectionStatus.disconnected);
    _retryAttempt++;
    final delaySeconds = [1, 2, 5, 10, 30][(_retryAttempt - 1).clamp(0, 4)];
    Future.delayed(Duration(seconds: delaySeconds), connect);
  }

  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _channel?.sink.close();
    _entityController.close();
    _statusController.close();
  }
}
