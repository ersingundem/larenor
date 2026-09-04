import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';

import 'fake_socket.dart';

void main() {
  test('connected follows subscription acknowledgement and replays to late listeners', () async {
    final socket = FakeSocket();
    final client = HaWebSocketClient(
      baseUrl: 'http://ha.test',
      token: 'example',
      channelFactory: (_) => socket,
    );
    addTearDown(client.dispose);
    final statuses = <HaConnectionStatus>[];
    final listener = client.status.listen(statuses.add);
    addTearDown(listener.cancel);
    client.connect();
    await socket.authenticate(acknowledgeSubscription: false);
    expect(statuses.last, HaConnectionStatus.connecting);
    expect(socket.sent.first, {'type': 'auth', 'access_token': 'example'});
    socket.emit({
      'type': 'result',
      'id': socket.sent.last['id'],
      'success': true,
    });
    await flushEvents();
    expect(statuses.last, HaConnectionStatus.connected);
    expect(await client.status.first, HaConnectionStatus.connected);
  });

  test(
    'a command issued during handshake waits for the subscription',
    () async {
      final socket = FakeSocket();
      final client = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        channelFactory: (_) => socket,
      );
      addTearDown(client.dispose);
      client.connect();
      final command = client.sendCommand({'type': 'config/area_registry/list'});
      await socket.authenticate();
      expect(socket.sent.last['type'], 'config/area_registry/list');
      socket.emit({
        'type': 'result',
        'id': socket.sent.last['id'],
        'success': true,
        'result': [],
      });
      expect(await command, isEmpty);
    },
  );

  test(
    'disconnect fails pending commands and opens only one replacement socket',
    () async {
      final sockets = <FakeSocket>[];
      final client = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        channelFactory: (_) {
          final socket = FakeSocket();
          sockets.add(socket);
          return socket;
        },
        reconnectDelay: (_) => const Duration(milliseconds: 1),
      );
      addTearDown(client.dispose);
      client.connect();
      client.connect();
      expect(sockets, hasLength(1));
      await sockets.first.authenticate();
      final command = client.sendCommand({'type': 'get_states'});
      final failure = expectLater(command, throwsA(isA<HaApiException>()));
      await sockets.first.incoming.close();
      await failure;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sockets, hasLength(2));
      expect(sockets.first.closed, isTrue);
      await sockets.last.authenticate();
      expect(await client.status.first, HaConnectionStatus.connected);
    },
  );

  test('dispose cancels a scheduled reconnect', () async {
    var count = 0;
    final socket = FakeSocket();
    final client = HaWebSocketClient(
      baseUrl: 'http://ha.test',
      token: 'example',
      channelFactory: (_) {
        count++;
        return socket;
      },
      reconnectDelay: (_) => const Duration(milliseconds: 10),
    );
    client.connect();
    await socket.incoming.close();
    client.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(count, 1);
  });

  test(
    'a synchronous socket write failure does not leak a pending command',
    () async {
      final socket = FakeSocket();
      final client = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        channelFactory: (_) => socket,
      );
      addTearDown(client.dispose);
      client.connect();
      await socket.authenticate();
      socket.failWrites = true;
      await expectLater(
        client.sendCommand({'type': 'get_states'}),
        throwsA(isA<HaApiException>()),
      );
      expect(await client.status.first, HaConnectionStatus.disconnected);
      await flushEvents();
    },
  );

  test(
    'invalid authentication does not retry the same rejected token',
    () async {
      var count = 0;
      final socket = FakeSocket();
      final client = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        channelFactory: (_) {
          count++;
          return socket;
        },
        reconnectDelay: (_) => const Duration(milliseconds: 1),
      );
      addTearDown(client.dispose);
      client.connect();
      socket.emit({'type': 'auth_invalid', 'message': 'Invalid token'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(count, 1);
      expect(await client.status.first, HaConnectionStatus.disconnected);
      await expectLater(
        client.sendCommand({'type': 'get_states'}),
        throwsA(isA<HaApiException>()),
      );
    },
  );
}
