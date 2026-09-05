import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'ha_api_exception.dart';
import 'ha_endpoint.dart';
import 'models/ha_entity.dart';

enum HaConnectionStatus { connecting, connected, disconnected }

enum HaConnectionEvent {
  connecting,
  contact,
  liveReady,
  liveContact,
  authenticationRejected,
  permissionDenied,
  disconnected,
  retrying,
}

/// Contains connection evidence only, never server text, tokens or payloads.
class HaConnectionObservation {
  const HaConnectionObservation(this.event, {this.retryAttempt = 0});
  final HaConnectionEvent event;
  final int retryAttempt;
}

class HaEntityChange {
  const HaEntityChange({required this.entityId, this.entity, this.time});

  final String entityId;
  final HaEntity? entity;
  final DateTime? time;
}

class HaSubscription {
  HaSubscription._(this.events, this._cancel);
  final Stream<dynamic> events;
  final Future<void> Function() _cancel;
  Future<void> cancel() => _cancel();
}

class _LiveSubscription {
  _LiveSubscription(this.command, this.controller);
  final Map<String, dynamic> command;
  final StreamController<dynamic> controller;
  int? wireId;
  bool cancelled = false;
}

/// Thin wrapper over Home Assistant's WebSocket API (`/api/websocket`).
///
/// Handles the auth handshake, subscribes to `state_changed` events, and
/// reconnects with exponential backoff on disconnect.
/// See https://developers.home-assistant.io/docs/api/websocket/
class HaWebSocketClient {
  HaWebSocketClient({
    required String baseUrl,
    required this.token,
    WebSocketChannel Function(Uri)? channelFactory,
    Duration Function(int attempt)? reconnectDelay,
    this.heartbeatInterval = const Duration(seconds: 30),
    this.connectionObserver,
  }) : _wsUrl = _toWsUrl(baseUrl),
       _channelFactory = channelFactory ?? WebSocketChannel.connect,
       _reconnectDelay = reconnectDelay ?? _defaultReconnectDelay;

  final String _wsUrl;
  final String token;
  final WebSocketChannel Function(Uri) _channelFactory;
  final Duration Function(int) _reconnectDelay;
  final Duration heartbeatInterval;
  final void Function(HaConnectionObservation)? connectionObserver;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  int _messageId = 1;
  bool _disposed = false;
  int _retryAttempt = 0;
  int? _eventsSubscriptionId;
  Timer? _reconnectTimer;
  Timer? _handshakeTimer;
  Timer? _heartbeatTimer;
  bool _pinging = false;
  bool _authenticationRejected = false;
  HaConnectionStatus _currentStatus = HaConnectionStatus.disconnected;

  final _entityController = StreamController<HaEntity>.broadcast();
  final _entityChangesController = StreamController<HaEntityChange>.broadcast();
  final _statusController = StreamController<HaConnectionStatus>.broadcast();
  final _pendingCommands = <int, Completer<dynamic>>{};
  final _liveSubscriptions = <_LiveSubscription>{};
  final _subscriptionsById = <int, _LiveSubscription>{};

  Stream<HaEntity> get entityUpdates => _entityController.stream;
  Stream<HaEntityChange> get entityChanges => _entityChangesController.stream;

  /// Include the current status for consumers attached after authentication.
  Stream<HaConnectionStatus> get status => Stream.multi((controller) {
    final subscription = _statusController.stream.listen(
      controller.add,
      onDone: controller.close,
    );
    controller.add(_currentStatus);
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Sends an arbitrary command (e.g. `config/device_registry/list`) and
  /// resolves with its `result` payload once the matching response arrives.
  Future<dynamic> sendCommand(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 15),
    bool Function()? isCurrent,
  }) async {
    await _waitUntilConnected();
    if (isCurrent != null && !isCurrent()) {
      throw HaApiException(
        'Operation is no longer current.',
        code: 'cancelled',
      );
    }
    return _sendCommand(command, timeout: timeout);
  }

  Future<void> _waitUntilConnected() async {
    if (!_disposed && _currentStatus == HaConnectionStatus.connecting) {
      await status
          .firstWhere((value) => value != HaConnectionStatus.connecting)
          .timeout(const Duration(seconds: 15));
    }
    if (_disposed || _currentStatus != HaConnectionStatus.connected) {
      throw HaApiException('Connection is not ready.', code: 'not_connected');
    }
  }

  Future<dynamic> _sendCommand(
    Map<String, dynamic> command, {
    int? messageId,
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (command['type'] is! String || (command['type'] as String).isEmpty) {
      throw ArgumentError('A WebSocket command needs a type.');
    }
    final id = messageId ?? _messageId++;
    final completer = Completer<dynamic>();
    _pendingCommands[id] = completer;
    try {
      _send({...command, 'id': id});
    } catch (_) {
      _pendingCommands.remove(id);
      _scheduleReconnect(_channel);
      throw HaApiException('Connection closed.');
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingCommands.remove(id);
        throw HaApiException(
          'Timed out waiting for a response.',
          code: 'timeout',
        );
      },
    );
  }

  static String _toWsUrl(String baseUrl) {
    final normalized = normalizeHaBaseUrl(baseUrl);
    final uri = haApiUri(normalized, '/api/websocket');
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri.replace(scheme: scheme).toString();
  }

  Future<void> ping() async =>
      sendCommand({'type': 'ping'}, timeout: const Duration(seconds: 10));

  Future<dynamic> callService(
    String domain,
    String service, {
    Map<String, dynamic>? serviceData,
    Map<String, dynamic>? target,
    bool returnResponse = false,
    bool Function()? isCurrent,
  }) => sendCommand(
    {
      'type': 'call_service',
      'domain': domain,
      'service': service,
      'service_data': ?serviceData,
      'target': ?target,
      if (returnResponse) 'return_response': true,
    },
    timeout: const Duration(seconds: 30),
    isCurrent: isCurrent,
  );

  /// Returns only after HA acknowledges the subscription. Early events are
  /// buffered until a listener attaches. Disconnect closes this stream with
  /// an error: the caller explicitly subscribes again, since lost events
  /// cannot be replayed by the HA event bus.
  Future<HaSubscription> subscribeCommand(Map<String, dynamic> command) async {
    await _waitUntilConnected();
    final controller = StreamController<dynamic>();
    final subscription = _LiveSubscription(
      Map.of(command)..remove('id'),
      controller,
    );
    controller.onCancel = () => _cancelSubscription(subscription);
    _liveSubscriptions.add(subscription);
    final id = _messageId++;
    subscription.wireId = id;
    _subscriptionsById[id] = subscription;
    try {
      await _sendCommand(subscription.command, messageId: id);
    } catch (error) {
      _subscriptionsById.remove(id);
      _liveSubscriptions.remove(subscription);
      subscription.cancelled = true;
      unawaited(controller.close());
      if (error is HaApiException && error.code == 'timeout') {
        // HA may have registered it even if its ACK was lost. Closing the
        // connection guarantees that no unreachable subscription survives.
        _scheduleReconnect(_channel);
      }
      rethrow;
    }
    return HaSubscription._(
      controller.stream,
      () => _cancelSubscription(subscription),
    );
  }

  Future<HaSubscription> subscribeEvents({String? eventType}) =>
      subscribeCommand({'type': 'subscribe_events', 'event_type': ?eventType});

  Future<HaSubscription> subscribeTrigger(
    Map<String, dynamic> trigger, {
    Map<String, dynamic>? variables,
  }) => subscribeCommand({
    'type': 'subscribe_trigger',
    'trigger': trigger,
    'variables': ?variables,
  });

  Future<HaSubscription> subscribeTemplate(
    String template, {
    Map<String, dynamic>? variables,
  }) => subscribeCommand({
    'type': 'render_template',
    'template': template,
    'variables': ?variables,
  });

  Future<void> _cancelSubscription(_LiveSubscription subscription) async {
    if (subscription.cancelled) return;
    subscription.cancelled = true;
    _liveSubscriptions.remove(subscription);
    final id = subscription.wireId;
    _subscriptionsById.remove(id);
    if (!_disposed &&
        id != null &&
        _currentStatus == HaConnectionStatus.connected) {
      try {
        await sendCommand({'type': 'unsubscribe_events', 'subscription': id});
      } on HaApiException {
        // A disconnect already removes every server-side subscription.
      }
    }
    unawaited(subscription.controller.close());
  }

  void connect() {
    if (_disposed || _authenticationRejected || _channel != null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setStatus(HaConnectionStatus.connecting);
    _observe(HaConnectionEvent.connecting);

    final WebSocketChannel channel;
    try {
      channel = _channelFactory(Uri.parse(_wsUrl));
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channel = channel;

    _subscription = channel.stream.listen(
      (raw) {
        if (identical(_channel, channel)) _onMessage(raw);
      },
      onError: (_) => _scheduleReconnect(channel),
      onDone: () => _scheduleReconnect(channel),
      cancelOnError: true,
    );
    unawaited(
      channel.ready.catchError((Object _) => _scheduleReconnect(channel)),
    );
    _handshakeTimer = Timer(
      const Duration(seconds: 15),
      () => _scheduleReconnect(channel),
    );
  }

  void _onMessage(dynamic raw) {
    try {
      final decoded = jsonDecode(raw as String);
      final messages = decoded is List ? decoded : [decoded];
      for (final message in messages) {
        if (message is! Map<String, dynamic>) throw const FormatException();
        _handleMessage(message);
      }
    } on FormatException {
      _scheduleReconnect(_channel);
    } on TypeError {
      _scheduleReconnect(_channel);
    }
  }

  void _handleMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'auth_required':
        _observe(HaConnectionEvent.contact);
        _send({'type': 'auth', 'access_token': token});
      case 'auth_ok':
        _observe(HaConnectionEvent.contact);
        _eventsSubscriptionId = _messageId++;
        _send({
          'id': _eventsSubscriptionId,
          'type': 'subscribe_events',
          'event_type': 'state_changed',
        });
      case 'auth_invalid':
        // Retrying the same rejected token cannot recover. A changed config
        // creates a new client through the provider.
        _authenticationRejected = true;
        _observe(HaConnectionEvent.authenticationRejected);
        _scheduleReconnect(_channel);
      case 'event':
        _handleEvent(message);
        _observe(HaConnectionEvent.liveContact);
      case 'result':
        _handleResult(message);
        _observe(HaConnectionEvent.liveContact);
      case 'pong':
        _handleResult({...message, 'success': true, 'result': null});
        _observe(HaConnectionEvent.liveContact);
    }
  }

  void _handleResult(Map<String, dynamic> message) {
    final id = message['id'] as int?;
    if (_eventsSubscriptionId != null && id == _eventsSubscriptionId) {
      if (message['success'] == true) {
        _retryAttempt = 0;
        _handshakeTimer?.cancel();
        _handshakeTimer = null;
        // Events cannot be considered live until HA acknowledges this
        // subscription; reconnect snapshot refreshes depend on this signal.
        _setStatus(HaConnectionStatus.connected);
        _observe(HaConnectionEvent.liveReady);
        _startHeartbeat();
      } else {
        if ((message['error'] as Map?)?['code'] == 'unauthorized') {
          _observe(HaConnectionEvent.permissionDenied);
        }
        _scheduleReconnect(_channel);
      }
      return;
    }
    final completer = id == null ? null : _pendingCommands.remove(id);
    if (completer == null) return;

    if (message['success'] == true) {
      completer.complete(message['result']);
    } else {
      final error = message['error'] as Map<String, dynamic>?;
      final errorMessage = error?['message'] as String? ?? 'Command failed.';
      completer.completeError(
        HaApiException(
          token.isEmpty
              ? errorMessage
              : errorMessage.replaceAll(token, '[redacted]'),
          code: error?['code'] as String?,
        ),
      );
    }
  }

  void _handleEvent(Map<String, dynamic> message) {
    final subscription = _subscriptionsById[message['id']];
    if (subscription != null && !subscription.cancelled) {
      subscription.controller.add(message['event']);
      return;
    }
    if (message['id'] != _eventsSubscriptionId) return;
    final event = message['event'] as Map<String, dynamic>?;
    if (event == null || event['event_type'] != 'state_changed') return;

    final data = event['data'] as Map<String, dynamic>;
    final newState = data['new_state'] as Map<String, dynamic>?;
    final entity = newState == null ? null : HaEntity.fromJson(newState);
    final entityId = entity?.entityId ?? data['entity_id'] as String?;
    if (entityId == null) return;
    final time =
        entity?.lastUpdated ??
        DateTime.tryParse(event['time_fired']?.toString() ?? '');
    _entityChangesController.add(
      HaEntityChange(entityId: entityId, entity: entity, time: time),
    );
    if (entity != null) _entityController.add(entity);
  }

  void _send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void _setStatus(HaConnectionStatus value) {
    if (_disposed || _currentStatus == value) return;
    _currentStatus = value;
    _statusController.add(value);
  }

  void _observe(HaConnectionEvent event, {int retryAttempt = 0}) {
    if (_disposed) return;
    try {
      connectionObserver?.call(
        HaConnectionObservation(event, retryAttempt: retryAttempt),
      );
    } catch (_) {
      // Optional monitoring must not interrupt the protocol state machine.
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    if (heartbeatInterval <= Duration.zero) return;
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (_pinging || _currentStatus != HaConnectionStatus.connected) return;
      _pinging = true;
      final channel = _channel;
      unawaited(
        ping()
            .catchError((Object _) {
              _scheduleReconnect(channel);
            })
            .whenComplete(() => _pinging = false),
      );
    });
  }

  static Duration _defaultReconnectDelay(int attempt) =>
      Duration(seconds: [1, 2, 5, 10, 30][(attempt - 1).clamp(0, 4)]);

  void _scheduleReconnect([WebSocketChannel? source]) {
    if (_disposed || (source != null && !identical(_channel, source))) return;
    if (_reconnectTimer != null) return;
    final channel = _channel;
    _channel = null;
    _eventsSubscriptionId = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(channel?.sink.close());
    _failPending();
    _setStatus(HaConnectionStatus.disconnected);
    _observe(HaConnectionEvent.disconnected);
    if (_authenticationRejected) return;
    _retryAttempt++;
    _observe(HaConnectionEvent.retrying, retryAttempt: _retryAttempt);
    _reconnectTimer = Timer(_reconnectDelay(_retryAttempt), () {
      _reconnectTimer = null;
      connect();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _handshakeTimer?.cancel();
    _heartbeatTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    unawaited(_entityController.close());
    unawaited(_entityChangesController.close());
    unawaited(_statusController.close());
    _failPending();
  }

  void _failPending() {
    for (final subscription in _liveSubscriptions) {
      subscription.cancelled = true;
      // Before ACK, the subscribing Future receives the pending-command
      // failure instead. There is no public stream listener yet.
      if (!_pendingCommands.containsKey(subscription.wireId)) {
        subscription.controller.addError(
          HaApiException('Connection closed.', code: 'closed'),
        );
      }
      unawaited(subscription.controller.close());
    }
    _liveSubscriptions.clear();
    _subscriptionsById.clear();
    for (final completer in _pendingCommands.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          HaApiException('Connection closed.', code: 'closed'),
        );
      }
    }
    _pendingCommands.clear();
  }
}
