import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';

import '../features/ha_client/fake_socket.dart';

void main() {
  test(
    '3000 wire events over 5000 entities publish one latest-state snapshot',
    () async {
      final rest = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'fixture',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode([
              for (var i = 0; i < 5000; i++)
                {'entity_id': 'sensor.$i', 'state': '0'},
            ]),
            200,
          ),
        ),
      );
      final socket = FakeSocket();
      final ws = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'fixture',
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
      var notifications = 0;
      container.listen(entitiesProvider, (_, _) => notifications++);
      final initial = await container.read(entitiesProvider.future);
      notifications = 0;
      for (var repeat = 1; repeat <= 3; repeat++) {
        for (var i = 0; i < 1000; i++) {
          socket.change('sensor.$i', '$repeat');
        }
      }
      await flushEvents();
      await flushEvents();
      final updated = container.read(entitiesProvider).requireValue;
      expect(notifications, 1);
      expect(updated, hasLength(5000));
      expect(updated['sensor.0']!.state, '3');
      expect(updated['sensor.999']!.state, '3');
      expect(identical(updated['sensor.4999'], initial['sensor.4999']), isTrue);
      // Provider snapshots remain immutable to consumers holding the old map.
      expect(initial['sensor.0']!.state, '0');

      socket.change('sensor.0', '3');
      await flushEvents();
      await flushEvents();
      expect(
        notifications,
        1,
        reason: 'An identical state must not emit again',
      );
    },
  );
}
