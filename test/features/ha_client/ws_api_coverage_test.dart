import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';

import 'fake_socket.dart';

void main() {
  Future<HaWebSocketClient> connected(FakeSocket socket) async {
    final client = HaWebSocketClient(
      baseUrl: 'https://ha.test',
      token: 'example',
      channelFactory: (_) => socket,
    )..connect();
    addTearDown(client.dispose);
    await socket.authenticate();
    return client;
  }

  test('WebSocket URI preserves a reverse proxy prefix', () async {
    final socket = FakeSocket();
    final client = HaWebSocketClient(
      baseUrl: ' https://ha.test/prefix/// ',
      token: 'example',
      channelFactory: (uri) {
        expect(uri.toString(), 'wss://ha.test/prefix/api/websocket');
        return socket;
      },
    )..connect();
    addTearDown(client.dispose);
    await socket.authenticate();
  });

  test('ping accepts pong instead of waiting for a result message', () async {
    final socket = FakeSocket();
    final client = await connected(socket);
    final pong = client.ping();
    await flushEvents();
    expect(socket.sent.last['type'], 'ping');
    socket.emit({'type': 'pong', 'id': socket.sent.last['id']});
    await pong;
  });

  test(
    'WS service call uses a separate target and a boolean response flag',
    () async {
      final socket = FakeSocket();
      final client = await connected(socket);
      final result = client.callService(
        'weather',
        'get_forecasts',
        serviceData: {'type': 'daily'},
        target: {'entity_id': 'weather.example'},
        returnResponse: true,
      );
      await flushEvents();
      final command = socket.sent.last;
      expect(command['service_data'], {'type': 'daily'});
      expect(command['target'], {'entity_id': 'weather.example'});
      expect(command['return_response'], isTrue);
      socket.emit({
        'type': 'result',
        'id': command['id'],
        'success': true,
        'result': {
          'context': {'id': 'example'},
          'response': {'forecast': []},
        },
      });
      expect((await result)['response'], {'forecast': []});
    },
  );

  test('subscription buffers early events, awaits ACK, and explicitly unsubscribes', () async {
    final socket = FakeSocket();
    final client = await connected(socket);
    var acknowledged = false;
    final pending = client.subscribeEvents(eventType: 'example_event').then((
      value,
    ) {
      acknowledged = true;
      return value;
    });
    await flushEvents();
    final id = socket.sent.last['id'];
    socket.emit({
      'type': 'event',
      'id': id,
      'event': {
        'event_type': 'example_event',
        'data': {'counter': 1},
      },
    });
    await flushEvents();
    expect(acknowledged, isFalse);
    socket.emit({'type': 'result', 'id': id, 'success': true, 'result': null});
    final subscription = await pending;
    final events = <dynamic>[];
    final done = Completer<void>();
    subscription.events.listen(events.add, onDone: done.complete);
    await flushEvents();
    expect(events.single['data']['counter'], 1);
    final cancelled = subscription.cancel();
    await flushEvents();
    expect(socket.sent.last['type'], 'unsubscribe_events');
    expect(socket.sent.last['subscription'], id);
    expect(socket.sent.last['id'], isNot(id));
    socket.emit({
      'type': 'result',
      'id': socket.sent.last['id'],
      'success': true,
      'result': null,
    });
    await cancelled;
    await done.future;
    final sent = socket.sent.length;
    await subscription.cancel();
    expect(socket.sent.length, sent);
  });

  test(
    'generic subscriptions retain compact and template event payloads',
    () async {
      final socket = FakeSocket();
      final client = await connected(socket);
      final pending = client.subscribeTemplate(
        '{{ value }}',
        variables: {'value': 42},
      );
      await flushEvents();
      final command = socket.sent.last;
      expect(command['type'], 'render_template');
      expect(command['variables'], {'value': 42});
      socket.emit({
        'type': 'result',
        'id': command['id'],
        'success': true,
        'result': null,
      });
      final subscription = await pending;
      final results = <dynamic>[];
      subscription.events.listen(results.add, onError: (_) {});
      socket.emit({
        'type': 'event',
        'id': command['id'],
        'event': {
          'result': 42,
          'listeners': {'all': false},
        },
      });
      await flushEvents();
      expect(results.single, {
        'result': 42,
        'listeners': {'all': false},
      });
    },
  );

  test('failed subscription ACK retains server error code', () async {
    final socket = FakeSocket();
    final client = await connected(socket);
    final pending = client.subscribeCommand({
      'type': 'unsupported_subscription',
    });
    final failed = expectLater(
      pending,
      throwsA(
        isA<HaApiException>().having(
          (error) => error.code,
          'code',
          'unknown_command',
        ),
      ),
    );
    await flushEvents();
    socket.emit({
      'type': 'result',
      'id': socket.sent.last['id'],
      'success': false,
      'error': {'code': 'unknown_command', 'message': 'Unknown command'},
    });
    await failed;
  });

  test('disconnect fails and closes live subscriptions without silent resubscription', () async {
    final socket = FakeSocket();
    final client = await connected(socket);
    final pending = client.subscribeEvents();
    await flushEvents();
    socket.emit({
      'type': 'result',
      'id': socket.sent.last['id'],
      'success': true,
      'result': null,
    });
    final subscription = await pending;
    final errors = <Object>[];
    final closed = Completer<void>();
    subscription.events.listen(
      (_) {},
      onError: errors.add,
      onDone: closed.complete,
    );
    await socket.incoming.close();
    await closed.future;
    expect(
      errors.single,
      isA<HaApiException>().having((error) => error.code, 'code', 'closed'),
    );
    await subscription.cancel();
  });

  test(
    'state removal is represented instead of being silently discarded',
    () async {
      final socket = FakeSocket();
      final client = await connected(socket);
      final updates = <HaEntityChange>[];
      final listener = client.entityChanges.listen(updates.add);
      addTearDown(listener.cancel);
      final id = socket.sent.firstWhere(
        (command) => command['type'] == 'subscribe_events',
      )['id'];
      socket.emit({
        'type': 'event',
        'id': id,
        'event': {
          'event_type': 'state_changed',
          'time_fired': '2026-09-04T10:00:00Z',
          'data': {'entity_id': 'sensor.removed', 'new_state': null},
        },
      });
      await flushEvents();
      expect(updates.single.entityId, 'sensor.removed');
      expect(updates.single.entity, isNull);
      expect(updates.single.time, DateTime.utc(2026, 9, 4, 10));
    },
  );

  test(
    'coalesced frames dispatch each result and event independently',
    () async {
      final socket = FakeSocket();
      final client = await connected(socket);
      final updates = <HaEntityChange>[];
      final listener = client.entityChanges.listen(updates.add);
      addTearDown(listener.cancel);
      final ping = client.ping();
      await flushEvents();
      final subscriptionId = socket.sent.firstWhere(
        (command) => command['type'] == 'subscribe_events',
      )['id'];
      socket.incoming.add(
        jsonEncode([
          {
            'type': 'event',
            'id': subscriptionId,
            'event': {
              'event_type': 'state_changed',
              'data': {
                'new_state': {'entity_id': 'light.example', 'state': 'on'},
              },
            },
          },
          {'type': 'pong', 'id': socket.sent.last['id']},
        ]),
      );
      await ping;
      await flushEvents();
      expect(updates.single.entity!.state, 'on');
    },
  );

  test(
    'malformed frames disconnect safely without uncaught parser errors',
    () async {
      final socket = FakeSocket();
      final client = await connected(socket);
      socket.incoming.add('not JSON');
      await flushEvents();
      expect(await client.status.first, HaConnectionStatus.disconnected);
    },
  );

  testWidgets('unanswered heartbeat reconnects a silently broken connection', (
    tester,
  ) async {
    final sockets = <FakeSocket>[];
    final client = HaWebSocketClient(
      baseUrl: 'http://ha.test',
      token: 'example',
      heartbeatInterval: const Duration(seconds: 1),
      channelFactory: (_) {
        final socket = FakeSocket();
        sockets.add(socket);
        return socket;
      },
    )..connect();
    addTearDown(client.dispose);
    sockets.first.emit({'type': 'auth_required'});
    await tester.pump();
    sockets.first.emit({'type': 'auth_ok'});
    await tester.pump();
    sockets.first.emit({
      'type': 'result',
      'id': sockets.first.sent.last['id'],
      'success': true,
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(sockets.first.sent.last['type'], 'ping');
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(sockets, hasLength(2));
    client.dispose();
    await tester.pump();
  });

  testWidgets(
    'lost subscription ACK closes its possibly active server stream',
    (tester) async {
      final socket = FakeSocket();
      final client = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        heartbeatInterval: Duration.zero,
        channelFactory: (_) => socket,
      )..connect();
      addTearDown(client.dispose);
      socket.emit({'type': 'auth_required'});
      await tester.pump();
      socket.emit({'type': 'auth_ok'});
      await tester.pump();
      socket.emit({
        'type': 'result',
        'id': socket.sent.last['id'],
        'success': true,
      });
      await tester.pump();
      Object? failure;
      unawaited(
        client.subscribeEvents().then<void>(
          (_) => fail('A missing subscription ACK must time out.'),
          onError: (Object error) => failure = error,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 15));
      expect(
        failure,
        isA<HaApiException>().having((error) => error.code, 'code', 'timeout'),
      );
      expect(socket.closed, isTrue);
      client.dispose();
      await tester.pump();
    },
  );
}
