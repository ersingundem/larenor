import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

typedef BrokerMessageHandler = Future<void> Function(BrokerMessage message);
typedef BrokerDisconnectHandler = void Function();

final class BrokerMessage {
  const BrokerMessage({
    required this.topic,
    required this.payload,
    required this.retained,
  });

  final String topic;
  final List<int> payload;
  final bool retained;
}

final class LocalMqttBrokerSettings {
  LocalMqttBrokerSettings({
    this.enabled = false,
    required this.host,
    required this.port,
    required this.tls,
  }) {
    if (host.isEmpty ||
        host != host.trim() ||
        host.length > 253 ||
        host.contains('://') ||
        host.contains('/') ||
        host.contains('@') ||
        host.contains('?') ||
        host.contains('#') ||
        host.runes.any((value) => value < 33 || value == 127) ||
        port < 1 ||
        port > 65535) {
      throw ArgumentError('invalid_mqtt_broker');
    }
  }

  final bool enabled;
  final String host;
  final int port;
  final bool tls;

  Map<String, Object> get publicMetadata => {
    'enabled': enabled,
    'host': host,
    'port': port,
    'tls': tls,
  };

  @override
  String toString() => 'LocalMqttBrokerSettings($publicMetadata)';
}

abstract interface class LocalMqttBroker {
  Future<void> connect({
    required LocalMqttBrokerSettings settings,
    required String clientId,
    required String username,
    required String password,
    required BrokerMessageHandler onMessage,
    required BrokerDisconnectHandler onDisconnected,
  });

  Future<void> subscribe(String topic);

  Future<void> publish(
    String topic,
    List<int> payload, {
    required bool retained,
  });

  Future<void> disconnect();
}

/// MQTT 3.1.1 adapter for an explicitly configured local broker.
///
/// Credentials are passed separately from the host and are never included in
/// a URL, diagnostic string or package logging. Reconnect is deliberately
/// owned by [ManagedTabletMqttRuntime], which rechecks pairing and egress
/// authority before every new socket.
final class MqttClientLocalBroker implements LocalMqttBroker {
  MqttClientLocalBroker({
    this.securityContext,
    this.subscriptionAckTimeout = const Duration(seconds: 5),
  }) : assert(subscriptionAckTimeout > Duration.zero);

  final SecurityContext? securityContext;
  final Duration subscriptionAckTimeout;
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  final Map<String, Completer<void>> _pendingSubscriptions = {};
  bool _closing = false;

  @override
  Future<void> connect({
    required LocalMqttBrokerSettings settings,
    required String clientId,
    required String username,
    required String password,
    required BrokerMessageHandler onMessage,
    required BrokerDisconnectHandler onDisconnected,
  }) async {
    if (!settings.enabled || !settings.tls) {
      throw StateError('mqtt_broker_disabled_or_insecure');
    }
    await disconnect();
    _closing = false;
    final client = MqttServerClient.withPort(
      settings.host,
      clientId,
      settings.port,
      maxConnectionAttempts: 1,
    );
    client
      ..setProtocolV311()
      ..secure = true
      ..securityContext = securityContext ?? SecurityContext.defaultContext
      ..keepAlivePeriod = 30
      ..autoReconnect = false
      ..logging(on: false, logPayloads: false)
      ..onSubscribed = _completeSubscription
      ..onSubscribeFail = _rejectSubscription
      ..onDisconnected = () {
        _rejectPendingSubscriptions('mqtt_disconnected');
        if (!_closing) onDisconnected();
      };
    _client = client;
    final status = await client.connect(username, password);
    if (status?.state != MqttConnectionState.connected ||
        status?.returnCode != MqttConnectReturnCode.connectionAccepted) {
      await disconnect();
      throw StateError('mqtt_connect_failed');
    }
    final updates = client.updates;
    if (updates == null) {
      await disconnect();
      throw StateError('mqtt_updates_unavailable');
    }
    _updates = updates.listen((batch) {
      for (final received in batch) {
        final message = received.payload;
        if (message is! MqttPublishMessage) continue;
        final bytes = message.payload.message;
        unawaited(
          onMessage(
            BrokerMessage(
              topic: received.topic,
              payload: Uint8List.fromList(bytes),
              retained: message.header?.retain == true,
            ),
          ),
        );
      }
    });
  }

  MqttServerClient get _connected {
    final client = _client;
    if (client?.connectionStatus?.state != MqttConnectionState.connected) {
      throw StateError('mqtt_not_connected');
    }
    return client!;
  }

  @override
  Future<void> subscribe(String topic) async {
    if (_pendingSubscriptions.containsKey(topic)) {
      throw StateError('mqtt_subscribe_in_flight');
    }
    final acknowledgement = Completer<void>();
    _pendingSubscriptions[topic] = acknowledgement;
    try {
      if (_connected.subscribe(topic, MqttQos.atLeastOnce) == null) {
        throw StateError('mqtt_subscribe_failed');
      }
      await acknowledgement.future.timeout(
        subscriptionAckTimeout,
        onTimeout: () => throw StateError('mqtt_subscribe_timeout'),
      );
    } finally {
      if (identical(_pendingSubscriptions[topic], acknowledgement)) {
        _pendingSubscriptions.remove(topic);
      }
    }
  }

  void _completeSubscription(String topic) {
    final pending = _pendingSubscriptions.remove(topic);
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  void _rejectSubscription(String topic) {
    final pending = _pendingSubscriptions.remove(topic);
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('mqtt_subscribe_rejected'));
    }
  }

  void _rejectPendingSubscriptions(String reason) {
    final pending = _pendingSubscriptions.values.toList(growable: false);
    _pendingSubscriptions.clear();
    for (final acknowledgement in pending) {
      if (!acknowledgement.isCompleted) {
        acknowledgement.completeError(StateError(reason));
      }
    }
  }

  @override
  Future<void> publish(
    String topic,
    List<int> payload, {
    required bool retained,
  }) async {
    final builder = MqttClientPayloadBuilder();
    builder.payload!.addAll(payload);
    _connected.publishMessage(
      topic,
      MqttQos.atLeastOnce,
      builder.payload!,
      retain: retained,
    );
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    _rejectPendingSubscriptions('mqtt_disconnected');
    await _updates?.cancel();
    _updates = null;
    _client?.disconnect();
    _client = null;
  }

  @override
  String toString() => 'MqttClientLocalBroker(credentials: redacted)';
}
