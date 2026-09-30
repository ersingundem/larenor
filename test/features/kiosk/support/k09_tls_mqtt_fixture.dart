import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class K09MqttPublication {
  const K09MqttPublication({
    required this.topic,
    required this.payload,
    required this.retained,
  });

  final String topic;
  final List<int> payload;
  final bool retained;

  Map<String, dynamic> json() {
    final value = jsonDecode(utf8.decode(payload, allowMalformed: false));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('mqtt_payload_not_object');
    }
    return value;
  }
}

final class K09MqttSession {
  const K09MqttSession({
    required this.clientId,
    required this.username,
    required this.password,
  });

  final String clientId, username, password;
}

/// Minimal owned MQTT 3.1.1/TLS peer for the production K09 client adapter.
///
/// It accepts CONNECT and QoS-1 PUBLISH only, acknowledges every received
/// publication, and records bytes before acknowledging them. It never emits a
/// remote command or simulates a screen-frame success.
final class K09TlsMqttFixture {
  K09TlsMqttFixture._({
    required this.server,
    required this.clientContext,
    required this.temporaryDirectory,
  });

  final SecureServerSocket server;
  final SecurityContext clientContext;
  final Directory temporaryDirectory;
  final publications = <K09MqttPublication>[];
  final sessions = <K09MqttSession>[];
  final _sockets = <SecureSocket>[];
  final _workers = <Future<void>>[];
  StreamSubscription<SecureSocket>? _accepts;
  int disconnects = 0;

  int get port => server.port;

  static Future<K09TlsMqttFixture> start() async {
    final directory = await Directory.systemTemp.createTemp(
      'larenor-k09-mqtt-',
    );
    final certificate = File('${directory.path}/certificate.pem');
    final privateKey = File('${directory.path}/private-key.pem');
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
      await directory.delete(recursive: true);
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
    final fixture = K09TlsMqttFixture._(
      server: server,
      clientContext: clientContext,
      temporaryDirectory: directory,
    );
    fixture._accepts = server.listen(fixture._accepted);
    return fixture;
  }

  void _accepted(SecureSocket socket) {
    _sockets.add(socket);
    final worker = _serve(socket);
    _workers.add(worker);
    unawaited(worker.catchError((_) {}));
  }

  Future<void> _serve(SecureSocket socket) async {
    final reader = _MqttReader(socket);
    try {
      final connect = await reader.next().timeout(const Duration(seconds: 5));
      if (connect.type != 1) throw StateError('mqtt_connect_required');
      sessions.add(_decodeConnect(connect.body));
      socket.add(const [0x20, 0x02, 0x00, 0x00]);
      await socket.flush();
      while (true) {
        final packet = await reader.next();
        if (packet.type == 3) {
          final publication = _decodePublish(packet);
          publications.add(publication.value);
          final identifier = publication.identifier;
          if (identifier != null) {
            socket.add([0x40, 0x02, identifier.$1, identifier.$2]);
            await socket.flush();
          }
        } else if (packet.type == 12) {
          socket.add(const [0xd0, 0x00]);
          await socket.flush();
        } else if (packet.type == 14) {
          break;
        } else {
          throw StateError('mqtt_packet_not_allowed:${packet.type}');
        }
      }
    } on StateError catch (error) {
      if (error.message != 'mqtt_socket_closed') rethrow;
    } finally {
      disconnects += 1;
      _sockets.remove(socket);
      await socket.close();
    }
  }

  Future<K09MqttPublication> waitFor(
    bool Function(K09MqttPublication value) predicate, {
    int occurrence = 1,
  }) async {
    if (occurrence < 1) throw ArgumentError.value(occurrence);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final matching = publications.where(predicate).toList(growable: false);
      if (matching.length >= occurrence) return matching[occurrence - 1];
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException(
      'mqtt_publication_not_observed:'
      '${publications.map((value) => value.topic.endsWith('/receipt') ? '${value.topic}:${value.json()}' : value.topic).join(',')}',
    );
  }

  Future<void> waitForDisconnects(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (disconnects >= count) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException('mqtt_disconnect_not_observed');
  }

  Future<void> close() async {
    for (final socket in [..._sockets]) {
      socket.destroy();
    }
    unawaited(server.close());
    final accepts = _accepts;
    if (accepts != null) unawaited(accepts.cancel());
    await Future.wait(_workers.map((worker) => worker.catchError((_) {})))
        .timeout(const Duration(seconds: 5), onTimeout: () => <void>[]);
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  }
}

final class _MqttPacket {
  const _MqttPacket(this.header, this.body);
  final int header;
  final List<int> body;
  int get type => header >> 4;
}

final class _MqttReader {
  _MqttReader(Stream<List<int>> stream) : _iterator = StreamIterator(stream);
  final StreamIterator<List<int>> _iterator;
  final _buffer = <int>[];

  Future<int> _byte() async {
    while (_buffer.isEmpty) {
      if (!await _iterator.moveNext()) throw StateError('mqtt_socket_closed');
      _buffer.addAll(_iterator.current);
    }
    return _buffer.removeAt(0);
  }

  Future<_MqttPacket> next() async {
    final header = await _byte();
    var remaining = 0, multiplier = 1;
    while (true) {
      final value = await _byte();
      remaining += (value & 0x7f) * multiplier;
      if (value & 0x80 == 0) break;
      multiplier *= 128;
      if (multiplier > 128 * 128 * 128) {
        throw StateError('invalid_mqtt_remaining_length');
      }
    }
    final body = <int>[];
    while (body.length < remaining) {
      body.add(await _byte());
    }
    return _MqttPacket(header, body);
  }
}

K09MqttSession _decodeConnect(List<int> body) {
  var offset = 0;
  final protocol = _readUtf8(body, offset);
  offset = protocol.next;
  if (protocol.value != 'MQTT' || body[offset++] != 4) {
    throw StateError('invalid_mqtt_connect');
  }
  final flags = body[offset++];
  if (flags & 0xc0 != 0xc0) throw StateError('mqtt_credentials_required');
  offset += 2;
  final client = _readUtf8(body, offset);
  offset = client.next;
  final username = _readUtf8(body, offset);
  offset = username.next;
  final password = _readUtf8(body, offset);
  return K09MqttSession(
    clientId: client.value,
    username: username.value,
    password: password.value,
  );
}

({K09MqttPublication value, (int, int)? identifier}) _decodePublish(
  _MqttPacket packet,
) {
  final topic = _readUtf8(packet.body, 0);
  var offset = topic.next;
  (int, int)? identifier;
  final qos = packet.header >> 1 & 0x03;
  if (qos == 1) {
    identifier = (packet.body[offset], packet.body[offset + 1]);
    offset += 2;
  } else if (qos != 0) {
    throw StateError('mqtt_qos_not_allowed');
  }
  return (
    value: K09MqttPublication(
      topic: topic.value,
      payload: packet.body.sublist(offset),
      retained: packet.header & 0x01 == 1,
    ),
    identifier: identifier,
  );
}

({String value, int next}) _readUtf8(List<int> bytes, int offset) {
  if (offset + 2 > bytes.length) throw StateError('invalid_mqtt_utf8');
  final length = bytes[offset] << 8 | bytes[offset + 1];
  final start = offset + 2, end = start + length;
  if (end > bytes.length) throw StateError('invalid_mqtt_utf8');
  return (
    value: utf8.decode(bytes.sublist(start, end), allowMalformed: false),
    next: end,
  );
}
