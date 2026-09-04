import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_health_bindings.dart';
import 'package:larenor/features/health/data/action_controller.dart';
import 'package:larenor/features/health/data/action_receipt.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/action_providers.dart';
import 'package:larenor/features/health/providers/ha_actions.dart';
import 'package:larenor/features/health/providers/health_providers.dart';

import '../ha_client/fake_socket.dart';

void main() {
  test(
    'equal credential reread preserves active session; token change resets it',
    () {
      final monitor = HealthMonitor();
      addTearDown(monitor.dispose);
      final config = HaConnectionConfig(
        baseUrl: 'http://ha.test',
        token: 'fixture',
      );
      final session = monitor.bind(
        IntegrationId.ha,
        configured: true,
        configurationIdentity: config,
      )..readSucceeded();
      final previous = monitor.read(IntegrationId.ha);
      monitor.synchronizeConfiguration(
        IntegrationId.ha,
        HaConnectionConfig(baseUrl: 'http://ha.test', token: 'fixture'),
      );
      expect(monitor.read(IntegrationId.ha), same(previous));
      session.failed(HealthFailure.permission);
      expect(monitor.read(IntegrationId.ha).failure, HealthFailure.permission);
      monitor.synchronizeConfiguration(
        IntegrationId.ha,
        HaConnectionConfig(baseUrl: 'http://ha.test', token: 'changed'),
      );
      session.readSucceeded();
      expect(monitor.read(IntegrationId.ha).lastSuccessfulRead, isNull);
    },
  );

  test(
    'configuration change drops only old integration receipts and guards',
    () async {
      final monitor = HealthMonitor();
      final container = ProviderContainer(
        overrides: [healthMonitorProvider.overrideWithValue(monitor)],
      );
      addTearDown(container.dispose);
      addTearDown(monitor.dispose);
      monitor.synchronizeConfiguration(IntegrationId.ha, Object());
      final controller = container.read(actionControllerProvider);
      final pending = Completer<void>();
      final key = ActionKey(
        integration: IntegrationId.ha,
        target: 'light.lamp',
        action: 'light.turn_on',
      );
      final old = controller.execute<void>(
        key: key,
        send: () => pending.future,
      );
      await controller.execute<void>(
        key: ActionKey(
          integration: IntegrationId.proxmox,
          target: 'vm.100',
          action: 'start',
        ),
        send: () async {},
      );
      monitor.synchronizeConfiguration(IntegrationId.ha, Object());
      expect((await old).status, ActionStatus.unknown);
      expect(controller.isPending(key), isFalse);
      expect(controller.receipts.map((value) => value.key.integration), [
        IntegrationId.proxmox,
      ]);
      expect(
        (await controller.execute<void>(key: key, send: () async {})).status,
        ActionStatus.accepted,
      );
      pending.complete();
      await flushEvents();
      expect(controller.receipts.first.status, ActionStatus.accepted);
    },
  );

  test(
    'real HA snapshot + unchanged entity + heartbeat remains fresh',
    () async {
      var now = DateTime.utc(2026, 9, 5);
      final monitor = HealthMonitor(now: () => now);
      final health = monitor.bind(IntegrationId.ha, configured: true);
      final socket = FakeSocket();
      final ws = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'fixture',
        channelFactory: (_) => socket,
        connectionObserver: (event) => observeHaConnection(health, event),
      )..connect();
      final rest = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'fixture',
        healthSession: health,
        observer: health.observeTransport,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {
                'entity_id': 'light.lamp',
                'state': 'off',
                'last_updated': '2020-01-01T00:00:00Z',
              },
            ]),
            200,
          ),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          haRestClientProvider.overrideWith((_) => rest),
          haWebSocketClientProvider.overrideWith((_) => ws),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(rest.dispose);
      addTearDown(ws.dispose);
      addTearDown(monitor.dispose);
      await socket.authenticate();
      container.listen(entitiesProvider, (_, _) {});
      await container.read(entitiesProvider.future);
      expect(monitor.read(IntegrationId.ha).lastSuccessfulRead, now);
      now = now.add(const Duration(hours: 2));
      final pong = ws.ping();
      await flushEvents();
      socket.emit({'type': 'pong', 'id': socket.sent.last['id']});
      await pong;
      expect(
        monitor.read(IntegrationId.ha).statusAt(now),
        HealthStatus.healthy,
      );
      expect(
        container
            .read(entitiesProvider)
            .value!['light.lamp']!
            .lastUpdated!
            .year,
        2020,
      );
    },
  );

  test('HA rejected WS auth is recorded and does not retry', () async {
    final monitor = HealthMonitor();
    final health = monitor.bind(IntegrationId.ha, configured: true);
    final socket = FakeSocket();
    var connects = 0;
    final ws = HaWebSocketClient(
      baseUrl: 'http://ha.test',
      token: 'fixture',
      channelFactory: (_) {
        connects++;
        return socket;
      },
      connectionObserver: (event) => observeHaConnection(health, event),
      reconnectDelay: (_) => Duration.zero,
    )..connect();
    addTearDown(ws.dispose);
    addTearDown(monitor.dispose);
    socket.emit({
      'type': 'auth_invalid',
      'message': 'ignored credential fixture',
    });
    await flushEvents();
    await flushEvents();
    expect(
      monitor.read(IntegrationId.ha).statusAt(DateTime.now()),
      HealthStatus.authenticationRequired,
    );
    expect(monitor.read(IntegrationId.ha).lastContact, isNotNull);
    expect(connects, 1);
  });

  test('HA malformed 200 snapshot never becomes successful read', () async {
    final monitor = HealthMonitor();
    final health = monitor.bind(IntegrationId.ha, configured: true);
    final rest = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'fixture',
      healthSession: health,
      observer: health.observeTransport,
      httpClient: MockClient((_) async => http.Response('{bad', 200)),
    );
    final container = ProviderContainer(
      overrides: [
        haRestClientProvider.overrideWith((_) => rest),
        haWebSocketClientProvider.overrideWith((_) => null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(rest.dispose);
    addTearDown(monitor.dispose);
    await expectLater(
      container.read(entitiesProvider.future),
      throwsA(anything),
    );
    expect(monitor.read(IntegrationId.ha).lastSuccessfulRead, isNull);
    expect(
      monitor.read(IntegrationId.ha).failure,
      HealthFailure.invalidResponse,
    );
    expect(monitor.read(IntegrationId.ha).lastContact, isNotNull);
  });

  test(
    'HA native action confirms only target changes and never widens target',
    () async {
      final socket = FakeSocket();
      final ws = HaWebSocketClient(
        baseUrl: 'http://ha.test',
        token: 'fixture',
        channelFactory: (_) => socket,
      )..connect();
      await socket.authenticate();
      final requests = <http.Request>[];
      final ack = Completer<http.Response>();
      final rest = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'fixture',
        httpClient: MockClient((request) {
          requests.add(request);
          return ack.future;
        }),
      );
      final controller = ActionController();
      final executor = HaActionExecutor(
        controller: controller,
        rest: rest,
        ws: ws,
      );
      addTearDown(ws.dispose);
      addTearDown(rest.dispose);
      addTearDown(controller.dispose);
      final result = executor.executeWithReceipt(
        domain: 'light',
        service: 'turn_on',
        entityId: 'light.lamp',
      );
      socket.change('light.lamp', 'on');
      socket.change('light.other', 'off');
      await flushEvents();
      ack.complete(http.Response('[]', 200));
      expect((await result).status, ActionStatus.confirmed);
      expect(jsonDecode(requests.single.body), {'entity_id': 'light.lamp'});
      expect(
        () => executor.executeWithReceipt(
          domain: 'light',
          service: 'turn_on',
          entityId: 'light.lamp',
          serviceData: {'area_id': 'all'},
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'HTTP permission rejection and absent client are known failures',
    () async {
      final controller = ActionController();
      final rest = HaRestClient(
        baseUrl: 'http://ha.test',
        token: 'fixture',
        httpClient: MockClient((_) async => http.Response('denied', 403)),
      );
      addTearDown(controller.dispose);
      addTearDown(rest.dispose);
      final executor = HaActionExecutor(controller: controller, rest: rest);
      final result = await executor.executeWithReceipt(
        domain: 'light',
        service: 'turn_on',
        entityId: 'light.lamp',
      );
      expect(result.status, ActionStatus.failed);
      expect(result.failure, ActionFailure.permission);
      final missing = await HaActionExecutor(controller: controller)
          .executeWithReceipt(
            domain: 'scene',
            service: 'turn_on',
            entityId: 'scene.night',
          );
      expect(missing.failure, ActionFailure.notConnected);
    },
  );

  test(
    'brightness confirmation checks quantized requested level, not on alone',
    () {
      final matches = expectedHaState('light.lamp', 'turn_on', {
        'brightness_pct': 50,
      })!;
      expect(
        matches(
          const HaEntity(
            entityId: 'light.lamp',
            state: 'on',
            attributes: {'brightness': 30},
          ),
        ),
        isFalse,
      );
      expect(
        matches(
          const HaEntity(
            entityId: 'light.lamp',
            state: 'on',
            attributes: {'brightness': 128},
          ),
        ),
        isTrue,
      );
      expect(
        expectedHaState('light.lamp', 'turn_on', {
          'brightness_pct': 50,
          'rgb_color': [255, 0, 0],
        }),
        isNull,
      );
      expect(expectedHaState('scene.night', 'turn_on', {}), isNull);
    },
  );

  test(
    'climate confirmation is requested setpoint, not measured temperature',
    () {
      final matches = expectedHaState('climate.room', 'set_temperature', {
        'temperature': 22,
      })!;
      expect(
        matches(
          const HaEntity(
            entityId: 'climate.room',
            state: 'heat',
            attributes: {'current_temperature': 22, 'temperature': 19},
          ),
        ),
        isFalse,
      );
      expect(
        matches(
          const HaEntity(
            entityId: 'climate.room',
            state: 'heat',
            attributes: {'current_temperature': 19, 'temperature': 22},
          ),
        ),
        isTrue,
      );
    },
  );
}
