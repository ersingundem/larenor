import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';

import 'fake_socket.dart';

http.Response snapshot(
  String state, {
  String? updated,
  bool extraEntity = false,
}) => http.Response(
  jsonEncode([
    {'entity_id': 'light.lamp', 'state': state, 'last_updated': ?updated},
    if (extraEntity) {'entity_id': 'light.removed', 'state': 'off'},
  ]),
  200,
);

void main() {
  test(
    'state deletions received during and after a snapshot remove the entity',
    () async {
      final response = Completer<http.Response>();
      final rest = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        httpClient: MockClient((_) => response.future),
      );
      final socket = FakeSocket();
      final ws = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        channelFactory: (_) => socket,
      )..connect();
      await socket.authenticate();
      final container = ProviderContainer(
        overrides: [
          haRestClientProvider.overrideWith((_) => rest),
          haWebSocketClientProvider.overrideWith((_) => ws),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(rest.dispose);
      addTearDown(ws.dispose);
      container.listen(entitiesProvider, (_, _) {});
      final ready = container.read(entitiesProvider.future);
      void remove() => socket.emit({
        'type': 'event',
        'id': socket.sent.firstWhere(
          (command) => command['type'] == 'subscribe_events',
        )['id'],
        'event': {
          'event_type': 'state_changed',
          'data': {'entity_id': 'light.lamp', 'new_state': null},
        },
      });
      remove();
      await flushEvents();
      response.complete(snapshot('on'));
      expect(await ready, isEmpty);
      socket.change('light.lamp', 'on');
      await flushEvents();
      expect(container.read(entitiesProvider).value, contains('light.lamp'));
      remove();
      await flushEvents();
      expect(container.read(entitiesProvider).value, isEmpty);
    },
  );

  test(
    'buffers events during initial REST fetch and continues receiving updates',
    () async {
      final response = Completer<http.Response>();
      final rest = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        httpClient: MockClient((_) => response.future),
      );
      final socket = FakeSocket();
      final ws = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        channelFactory: (_) => socket,
      )..connect();
      await socket.authenticate();
      final container = ProviderContainer(
        overrides: [
          haRestClientProvider.overrideWith((_) => rest),
          haWebSocketClientProvider.overrideWith((_) => ws),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(rest.dispose);
      addTearDown(ws.dispose);
      container.listen(entitiesProvider, (_, _) {});
      final ready = container.read(entitiesProvider.future);
      socket.change('light.lamp', 'on', updated: '2026-09-04T10:01:00Z');
      await flushEvents();
      response.complete(snapshot('off', updated: '2026-09-04T10:00:00Z'));
      expect((await ready)['light.lamp']!.state, 'on');
      socket.change('light.lamp', 'off', updated: '2026-09-04T10:02:00Z');
      await flushEvents();
      expect(
        container.read(entitiesProvider).value!['light.lamp']!.state,
        'off',
      );
    },
  );

  test(
    'an older buffered event cannot overwrite a newer REST snapshot',
    () async {
      final response = Completer<http.Response>();
      final rest = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        httpClient: MockClient((_) => response.future),
      );
      final socket = FakeSocket();
      final ws = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        channelFactory: (_) => socket,
      )..connect();
      await socket.authenticate();
      final container = ProviderContainer(
        overrides: [
          haRestClientProvider.overrideWith((_) => rest),
          haWebSocketClientProvider.overrideWith((_) => ws),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(rest.dispose);
      addTearDown(ws.dispose);
      container.listen(entitiesProvider, (_, _) {});
      final ready = container.read(entitiesProvider.future);
      socket.change('light.lamp', 'off', updated: '2026-09-04T10:00:00Z');
      await flushEvents();
      response.complete(snapshot('on', updated: '2026-09-04T10:01:00Z'));
      expect((await ready)['light.lamp']!.state, 'on');
    },
  );

  test(
    'reconnect refreshes missed changes and removes absent entities',
    () async {
      var reads = 0;
      final rest = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        httpClient: MockClient(
          (_) async => ++reads == 1
              ? snapshot('off', extraEntity: true)
              : snapshot('on'),
        ),
      );
      final sockets = <FakeSocket>[];
      final ws = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'example',
        channelFactory: (_) {
          final socket = FakeSocket();
          sockets.add(socket);
          return socket;
        },
        reconnectDelay: (_) => const Duration(milliseconds: 1),
      )..connect();
      await sockets.first.authenticate();
      final container = ProviderContainer(
        overrides: [
          haRestClientProvider.overrideWith((_) => rest),
          haWebSocketClientProvider.overrideWith((_) => ws),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(rest.dispose);
      addTearDown(ws.dispose);
      container.listen(entitiesProvider, (_, _) {});
      expect(
        await container.read(entitiesProvider.future),
        contains('light.removed'),
      );
      await sockets.first.incoming.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sockets.last.authenticate();
      await container.pump();
      final entities = await container.read(entitiesProvider.future);
      expect(reads, 2);
      expect(entities['light.lamp']!.state, 'on');
      expect(entities, isNot(contains('light.removed')));
    },
  );

  test('subscription activation resync cannot be overwritten by obsolete first fetch', () async {
    final oldResponse = Completer<http.Response>();
    var reads = 0;
    final rest = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'example',
      httpClient: MockClient(
        (_) => ++reads == 1 ? oldResponse.future : Future.value(snapshot('on')),
      ),
    );
    final socket = FakeSocket();
    final ws = HaWebSocketClient(
      baseUrl: 'http://ha.test',
      token: 'example',
      channelFactory: (_) => socket,
    )..connect();
    final container = ProviderContainer(
      overrides: [
        haRestClientProvider.overrideWith((_) => rest),
        haWebSocketClientProvider.overrideWith((_) => ws),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(rest.dispose);
    addTearDown(ws.dispose);
    container.listen(entitiesProvider, (_, _) {});
    await flushEvents();
    await socket.authenticate();
    await container.pump();
    expect(
      (await container.read(entitiesProvider.future))['light.lamp']!.state,
      'on',
    );
    oldResponse.complete(snapshot('off'));
    await flushEvents();
    expect(container.read(entitiesProvider).value!['light.lamp']!.state, 'on');
    socket.change('light.lamp', 'off');
    await flushEvents();
    expect(container.read(entitiesProvider).value!['light.lamp']!.state, 'off');
  });
}
