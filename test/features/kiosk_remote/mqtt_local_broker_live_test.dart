import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/runtime/mqtt_local_broker.dart';

void main() {
  test(
    'TLS adapter authenticates, subscribes and exchanges bounded MQTT packets',
    () async {
      final fixture = await _TlsMqttFixture.start();
      addTearDown(fixture.close);

      final received = Completer<BrokerMessage>();
      var unexpectedDisconnects = 0;
      final broker = MqttClientLocalBroker(
        securityContext: fixture.clientContext,
      );
      addTearDown(broker.disconnect);

      await broker.connect(
        settings: LocalMqttBrokerSettings(
          enabled: true,
          host: InternetAddress.loopbackIPv4.address,
          port: fixture.port,
          tls: true,
        ),
        clientId: 'larenor-tablet-fixture',
        username: 'fixture-user',
        password: 'fixture-password',
        onMessage: (message) async {
          if (!received.isCompleted) received.complete(message);
        },
        onDisconnected: () => unexpectedDisconnects += 1,
      );
      await broker.subscribe('larenor/tablets/device-1/commands');
      await broker.publish(
        'larenor/tablets/device-1/telemetry',
        utf8.encode('{"state":"ready"}'),
        retained: true,
      );

      final message = await received.future.timeout(const Duration(seconds: 5));
      expect(message.topic, 'larenor/tablets/device-1/commands');
      expect(utf8.decode(message.payload), '{"command":"refresh"}');
      expect(message.retained, isFalse);
      expect(
        await fixture.observation,
        const _ObservedSession(
          clientId: 'larenor-tablet-fixture',
          username: 'fixture-user',
          password: 'fixture-password',
          subscription: 'larenor/tablets/device-1/commands',
          publishedTopic: 'larenor/tablets/device-1/telemetry',
          publishedPayload: '{"state":"ready"}',
          publishedRetained: true,
        ),
      );

      await broker.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(unexpectedDisconnects, 0);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'TLS adapter fails closed when the broker rejects a subscription',
    () async {
      final fixture = await _TlsMqttFixture.start(rejectSubscription: true);
      addTearDown(fixture.close);
      final broker = MqttClientLocalBroker(
        securityContext: fixture.clientContext,
      );
      addTearDown(broker.disconnect);

      await broker.connect(
        settings: LocalMqttBrokerSettings(
          enabled: true,
          host: InternetAddress.loopbackIPv4.address,
          port: fixture.port,
          tls: true,
        ),
        clientId: 'larenor-tablet-rejected',
        username: 'fixture-user',
        password: 'fixture-password',
        onMessage: (_) async {},
        onDisconnected: () {},
      );

      await expectLater(
        broker.subscribe('larenor/tablets/device-1/rejected'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'mqtt_subscribe_rejected',
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'TLS adapter does not report publish success without broker receipt',
    () async {
      final fixture = await _TlsMqttFixture.start(suppressPublishAck: true);
      addTearDown(fixture.close);
      final broker = MqttClientLocalBroker(
        securityContext: fixture.clientContext,
        publishAckTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(broker.disconnect);

      await broker.connect(
        settings: LocalMqttBrokerSettings(
          enabled: true,
          host: InternetAddress.loopbackIPv4.address,
          port: fixture.port,
          tls: true,
        ),
        clientId: 'larenor-tablet-unacknowledged',
        username: 'fixture-user',
        password: 'fixture-password',
        onMessage: (_) async {},
        onDisconnected: () {},
      );
      await broker.subscribe('larenor/tablets/device-1/commands');

      await expectLater(
        broker.publish(
          'larenor/tablets/device-1/telemetry',
          utf8.encode('{"state":"ready"}'),
          retained: true,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'mqtt_publish_timeout',
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

final class _TlsMqttFixture {
  _TlsMqttFixture._({
    required this.server,
    required this.clientContext,
    required this.tempDirectory,
    required this.observation,
    required this.worker,
  });

  final SecureServerSocket server;
  final SecurityContext clientContext;
  final Directory tempDirectory;
  final Future<_ObservedSession> observation;
  final Future<void> worker;

  int get port => server.port;

  static Future<_TlsMqttFixture> start({
    bool rejectSubscription = false,
    bool suppressPublishAck = false,
  }) async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'larenor-mqtt-tls-',
    );
    final certificate = File('${tempDirectory.path}/certificate.pem');
    final privateKey = File('${tempDirectory.path}/private-key.pem');
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      privateKey.path,
      '-out',
      certificate.path,
      '-sha256',
      '-days',
      '1',
      '-nodes',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
      '-addext',
      'extendedKeyUsage=serverAuth',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
    ]);
    if (result.exitCode != 0) {
      await tempDirectory.delete(recursive: true);
      throw StateError('openssl_fixture_failed: ${result.stderr}');
    }

    final serverContext = SecurityContext()
      ..useCertificateChain(certificate.path)
      ..usePrivateKey(privateKey.path);
    final clientContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(certificate.path);
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    final observed = Completer<_ObservedSession>();
    final worker = _serve(
      server,
      observed,
      rejectSubscription: rejectSubscription,
      suppressPublishAck: suppressPublishAck,
    );
    return _TlsMqttFixture._(
      server: server,
      clientContext: clientContext,
      tempDirectory: tempDirectory,
      observation: observed.future,
      worker: worker,
    );
  }

  static Future<void> _serve(
    SecureServerSocket server,
    Completer<_ObservedSession> observed, {
    required bool rejectSubscription,
    required bool suppressPublishAck,
  }) async {
    try {
      final socket = await server.first.timeout(const Duration(seconds: 5));
      final reader = _MqttPacketReader(socket);
      final connect = await reader.next();
      expect(connect.type, 1);
      final credentials = _decodeConnect(connect.body);
      socket.add(const [0x20, 0x02, 0x00, 0x00]);
      await socket.flush();

      String? subscription;
      _PublishedPacket? published;
      while (subscription == null || published == null) {
        final packet = await reader.next();
        if (packet.type == 8) {
          final id = _packetIdentifier(packet.body);
          subscription = _readUtf8(packet.body, 2).value;
          socket.add([
            0x90,
            0x03,
            id.$1,
            id.$2,
            rejectSubscription ? 0x80 : 0x01,
          ]);
          await socket.flush();
          if (rejectSubscription) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await socket.close();
            return;
          }
        } else if (packet.type == 3) {
          published = _decodePublish(packet);
          final id = published.packetIdentifier;
          if (!suppressPublishAck && id != null) {
            socket.add([0x40, 0x02, id.$1, id.$2]);
            await socket.flush();
          }
        }
      }

      observed.complete(
        _ObservedSession(
          clientId: credentials.clientId,
          username: credentials.username,
          password: credentials.password,
          subscription: subscription,
          publishedTopic: published.topic,
          publishedPayload: utf8.decode(published.payload),
          publishedRetained: published.retained,
        ),
      );
      socket.add(
        _encodePublish(
          'larenor/tablets/device-1/commands',
          utf8.encode('{"command":"refresh"}'),
        ),
      );
      await socket.flush();
      await socket.done.timeout(const Duration(seconds: 5));
    } catch (error, stackTrace) {
      if (!observed.isCompleted) observed.completeError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> close() async {
    await server.close();
    try {
      await worker;
    } on Object {
      // The observation future surfaces protocol failures to the test.
    }
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  }
}

final class _MqttPacketReader {
  _MqttPacketReader(Stream<List<int>> stream)
    : _iterator = StreamIterator(stream);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = [];

  Future<int> _byte() async {
    while (_buffer.isEmpty) {
      if (!await _iterator.moveNext()) throw StateError('mqtt_socket_closed');
      _buffer.addAll(_iterator.current);
    }
    return _buffer.removeAt(0);
  }

  Future<_MqttPacket> next() async {
    final header = await _byte();
    var multiplier = 1;
    var remainingLength = 0;
    while (true) {
      final encoded = await _byte();
      remainingLength += (encoded & 0x7f) * multiplier;
      if ((encoded & 0x80) == 0) break;
      multiplier *= 128;
      if (multiplier > 128 * 128 * 128) {
        throw StateError('invalid_remaining_length');
      }
    }
    final body = <int>[];
    while (body.length < remainingLength) {
      body.add(await _byte());
    }
    return _MqttPacket(header: header, body: body);
  }
}

final class _MqttPacket {
  const _MqttPacket({required this.header, required this.body});

  final int header;
  final List<int> body;

  int get type => header >> 4;
}

final class _ConnectCredentials {
  const _ConnectCredentials({
    required this.clientId,
    required this.username,
    required this.password,
  });

  final String clientId;
  final String username;
  final String password;
}

_ConnectCredentials _decodeConnect(List<int> body) {
  var offset = 0;
  final protocol = _readUtf8(body, offset);
  offset = protocol.next;
  expect(protocol.value, 'MQTT');
  expect(body[offset++], 4);
  final flags = body[offset++];
  expect(flags & 0xc0, 0xc0);
  offset += 2;
  final clientId = _readUtf8(body, offset);
  offset = clientId.next;
  final username = _readUtf8(body, offset);
  offset = username.next;
  final password = _readUtf8(body, offset);
  return _ConnectCredentials(
    clientId: clientId.value,
    username: username.value,
    password: password.value,
  );
}

final class _PublishedPacket {
  const _PublishedPacket({
    required this.topic,
    required this.payload,
    required this.retained,
    required this.packetIdentifier,
  });

  final String topic;
  final List<int> payload;
  final bool retained;
  final (int, int)? packetIdentifier;
}

_PublishedPacket _decodePublish(_MqttPacket packet) {
  final topic = _readUtf8(packet.body, 0);
  var offset = topic.next;
  (int, int)? packetIdentifier;
  final qos = (packet.header >> 1) & 0x03;
  if (qos > 0) {
    packetIdentifier = (packet.body[offset], packet.body[offset + 1]);
    offset += 2;
  }
  return _PublishedPacket(
    topic: topic.value,
    payload: packet.body.sublist(offset),
    retained: packet.header & 0x01 == 1,
    packetIdentifier: packetIdentifier,
  );
}

(int, int) _packetIdentifier(List<int> body) => (body[0], body[1]);

({String value, int next}) _readUtf8(List<int> bytes, int offset) {
  final length = (bytes[offset] << 8) | bytes[offset + 1];
  final start = offset + 2;
  final end = start + length;
  return (value: utf8.decode(bytes.sublist(start, end)), next: end);
}

List<int> _encodePublish(String topic, List<int> payload) {
  final topicBytes = utf8.encode(topic);
  final body = <int>[
    topicBytes.length >> 8,
    topicBytes.length & 0xff,
    ...topicBytes,
    ...payload,
  ];
  return [0x30, ..._encodeRemainingLength(body.length), ...body];
}

List<int> _encodeRemainingLength(int value) {
  final encoded = <int>[];
  do {
    var digit = value % 128;
    value ~/= 128;
    if (value > 0) digit |= 0x80;
    encoded.add(digit);
  } while (value > 0);
  return encoded;
}

final class _ObservedSession {
  const _ObservedSession({
    required this.clientId,
    required this.username,
    required this.password,
    required this.subscription,
    required this.publishedTopic,
    required this.publishedPayload,
    required this.publishedRetained,
  });

  final String clientId;
  final String username;
  final String password;
  final String subscription;
  final String publishedTopic;
  final String publishedPayload;
  final bool publishedRetained;

  @override
  bool operator ==(Object other) =>
      other is _ObservedSession &&
      clientId == other.clientId &&
      username == other.username &&
      password == other.password &&
      subscription == other.subscription &&
      publishedTopic == other.publishedTopic &&
      publishedPayload == other.publishedPayload &&
      publishedRetained == other.publishedRetained;

  @override
  int get hashCode => Object.hash(
    clientId,
    username,
    password,
    subscription,
    publishedTopic,
    publishedPayload,
    publishedRetained,
  );
}
