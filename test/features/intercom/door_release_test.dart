import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_health_bindings.dart';
import 'package:larenor/features/ha_tools/presentation/ha_actions_screen.dart';
import 'package:larenor/features/health/data/action_receipt.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/action_providers.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/intercom/data/door_station_store.dart';
import 'package:larenor/features/intercom/domain/door_station.dart';
import 'package:larenor/features/intercom/providers/intercom_providers.dart';

import '../ha_client/fake_socket.dart';
import '../../core/direct_home_routines_test.dart' show routinesHome;
import 'door_station_test.dart' show fixtureStation;

class _Config extends ConnectionConfig {
  _Config(this.initial);
  final HaConnectionConfig initial;
  @override
  Future<HaConnectionConfig?> build() async => initial;
  void publish(HaConnectionConfig? next) => state = AsyncData(next);
}

class _Store extends DoorStationStore {
  _Store(this.stations);
  List<DoorStation> stations;
  @override
  Future<List<DoorStation>> read() async => stations;
}

class _Fixture {
  _Fixture({
    this.station = fixtureStation,
    this.codeRequired = false,
    this.home,
  });
  final HomeSessionController? home;
  final DoorStation station;
  final bool codeRequired;
  var now = DateTime.utc(2026, 9, 5);
  final config = const HaConnectionConfig(
    baseUrl: 'http://ha.test',
    token: 'fixture',
  );
  final socket = FakeSocket();
  final writes = <http.Request>[];
  int responseCode = 200;
  Object? sendError;
  Completer<void>? pendingSend;
  late final HealthMonitor monitor;
  late final HealthSession health;
  late final HaRestClient rest;
  late final HaWebSocketClient ws;
  late final ProviderContainer container;
  late final _Store store;

  Future<void> start() async {
    monitor = HealthMonitor(now: () => now);
    health = monitor.bind(
      IntegrationId.ha,
      configured: true,
      configurationIdentity: config,
    );
    ws = HaWebSocketClient(
      baseUrl: config.baseUrl,
      token: config.token,
      channelFactory: (_) => socket,
      connectionObserver: (event) => observeHaConnection(health, event),
    )..connect();
    rest = HaRestClient(
      baseUrl: config.baseUrl,
      token: config.token,
      healthSession: health,
      observer: health.observeTransport,
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          writes.add(request);
          if (pendingSend != null) await pendingSend!.future;
          if (sendError != null) throw sendError!;
          // Real HA state event can arrive before the service ACK.
          if (station.unlockEntityId!.startsWith('lock.')) {
            socket.change(station.unlockEntityId!, 'unlocked');
            await flushEvents();
          }
          return http.Response('[]', responseCode);
        }
        if (request.url.path == '/api/states') {
          return http.Response(
            jsonEncode([
              {
                'entity_id': station.unlockEntityId,
                'state': station.unlockEntityId!.startsWith('button.')
                    ? 'unknown'
                    : 'locked',
                'attributes': {if (codeRequired) 'code_format': r'^\d{4}$'},
              },
              {'entity_id': 'binary_sensor.call', 'state': 'on'},
              {'entity_id': 'binary_sensor.front', 'state': 'off'},
            ]),
            200,
          );
        }
        if (request.url.path == '/api/services') {
          return http.Response(
            jsonEncode([
              {
                'domain': 'button',
                'services': {
                  'press': {'target': {}},
                },
              },
              {
                'domain': 'lock',
                'services': {
                  'unlock': {
                    'target': {},
                    'fields': {'code': {}},
                  },
                },
              },
            ]),
            200,
          );
        }
        throw StateError('Unexpected fixture request.');
      }),
    );
    store = _Store([station]);
    container = ProviderContainer(
      overrides: [
        if (home != null) homeSessionControllerProvider.overrideWithValue(home),
        connectionConfigProvider.overrideWith(() => _Config(config)),
        doorStationStoreProvider.overrideWithValue(store),
        // Retain independently supplied old mapping/state to prove that source
        // ownership is required even when those other checks still pass.
        if (home != null)
          doorStationsProvider.overrideWith((_) async => [station]),
        healthMonitorProvider.overrideWithValue(monitor),
        doorReleaseClockProvider.overrideWithValue(() => now),
        haRestClientProvider.overrideWith((_) => rest),
        haWebSocketClientProvider.overrideWith((_) => ws),
      ],
    );
    await container.read(connectionConfigProvider.future);
    await socket.authenticate();
    container.listen(doorReleaseBlockProvider(station), (_, _) {});
    await container.read(entitiesProvider.future);
    await container.read(haActionsProvider.future);
    await container.read(doorStationsProvider.future);
    await flushEvents();
    expect(container.read(doorReleaseBlockProvider(station)), isNull);
  }

  DoorReleaseIntent prepare() =>
      container.read(doorReleaseIntentProvider)(station);
  Future<void> release(DoorReleaseIntent intent, {String? code}) =>
      container.read(doorReleaseActionProvider)(intent, code: code);
  void dispose() {
    container.dispose();
    rest.dispose();
    ws.dispose();
    monitor.dispose();
  }
}

Matcher blocked([DoorReleaseBlock? reason]) => throwsA(
  isA<DoorReleaseException>().having(
    (e) => reason == null || e.reason == reason,
    'fixed block reason',
    isTrue,
  ),
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  Future<_Fixture> fixture({
    DoorStation station = fixtureStation,
    bool codeRequired = false,
    HomeSessionController? home,
  }) async {
    final fixture = _Fixture(
      station: station,
      codeRequired: codeRequired,
      home: home,
    );
    addTearDown(fixture.dispose);
    await fixture.start();
    return fixture;
  }

  test(
    'REST healthy alone, disconnected socket and stale heartbeat never qualify',
    () {
      final now = DateTime.utc(2026, 9, 5);
      final restOnly = IntegrationHealth(
        configured: true,
        lastSuccessfulRead: now,
      );
      expect(restOnly.statusAt(now), HealthStatus.healthy);
      expect(doorReleaseHasLiveState(restOnly, now), isFalse);
      final live = restOnly.copyWith(
        liveUpdates: true,
        liveSnapshotSynchronized: true,
        lastLiveContact: now,
      );
      expect(doorReleaseHasLiveState(live, now), isTrue);
      expect(
        doorReleaseHasLiveState(
          live.copyWith(liveSnapshotSynchronized: false),
          now,
        ),
        isFalse,
      );
      expect(
        doorReleaseHasLiveState(live.copyWith(liveUpdates: false), now),
        isFalse,
      );
      expect(
        doorReleaseHasLiveState(live, now.add(const Duration(seconds: 76))),
        isFalse,
      );
      expect(
        doorReleaseHasLiveState(live, now.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    },
  );

  test(
    'unknown button permits one press, replay and double tap never send again',
    () async {
      final f = await fixture();
      final intent = f.prepare();
      final send = f.release(intent);
      await expectLater(
        f.release(intent),
        blocked(DoorReleaseBlock.intentExpired),
      );
      await send;
      await expectLater(
        f.release(intent),
        blocked(DoorReleaseBlock.intentExpired),
      );
      expect(f.writes.length, 1);
      expect(f.writes.single.url.path, '/api/services/button/press');
      expect(jsonDecode(f.writes.single.body), {'entity_id': 'button.release'});
      final receipts = f.container.read(actionControllerProvider).receipts;
      expect(receipts.single.status, ActionStatus.accepted);
    },
  );

  test(
    'call end immediately invalidates intent even before batched entities',
    () async {
      final f = await fixture();
      final intent = f.prepare();
      f.socket.change('binary_sensor.call', 'off');
      await flushEvents();
      await expectLater(f.release(intent), blocked());
      expect(f.writes, isEmpty);
    },
  );

  test('ended and new call cannot inherit confirmation', () async {
    final f = await fixture();
    final intent = f.prepare();
    f.socket.change('binary_sensor.call', 'off');
    f.socket.change('binary_sensor.call', 'on');
    await flushEvents();
    await expectLater(f.release(intent), blocked());
    expect(f.writes, isEmpty);
  });

  test('same server account change cancels visible intent', () async {
    final f = await fixture();
    final intent = f.prepare();
    (f.container.read(connectionConfigProvider.notifier) as _Config).publish(
      const HaConnectionConfig(
        baseUrl: 'http://ha.test',
        token: 'different-account',
      ),
    );
    await expectLater(f.release(intent), blocked());
    expect(f.writes, isEmpty);
  });

  test(
    'changed mapping cancels old target even after another mapping is loaded',
    () async {
      final f = await fixture();
      final intent = f.prepare();
      f.store.stations = [
        DoorStation.fromJson({
          ...fixtureStation.toJson(),
          'unlockEntityId': 'button.other',
        }),
      ];
      f.container.invalidate(doorStationsProvider);
      await f.container.read(doorStationsProvider.future);
      await expectLater(
        f.release(intent),
        blocked(DoorReleaseBlock.mappingChanged),
      );
      expect(f.writes, isEmpty);
    },
  );

  test('blocked non-commissioned mapping never prepares a command', () async {
    final f = await fixture();
    final disabled = DoorStation.fromJson({
      ...fixtureStation.toJson(),
      'unlockEnabled': false,
    });
    f.store.stations = [disabled];
    f.container.invalidate(doorStationsProvider);
    await f.container.read(doorStationsProvider.future);
    expect(
      () => f.container.read(doorReleaseIntentProvider)(disabled),
      blocked(DoorReleaseBlock.notCommissioned),
    );
    expect(f.writes, isEmpty);
  });

  test('unavailable button is blocked while its untouched unknown state is supported', () async {
    final f = await fixture();
    f.socket.change('button.release', 'unavailable');
    await flushEvents();
    await flushEvents();
    expect(() => f.prepare(), blocked(DoorReleaseBlock.unavailable));
    expect(f.writes, isEmpty);
  });

  test('direct health disconnect after confirm blocks without waiting for UI rebuild', () async {
    final f = await fixture();
    final intent = f.prepare();
    f.health.liveDisconnected();
    f.health.readSucceeded(); // REST success does not restore WS state.
    await expectLater(f.release(intent), blocked(DoorReleaseBlock.staleState));
    expect(f.writes, isEmpty);
  });

  test(
    'socket reconnect with a fresh snapshot does not renew a previous intent',
    () async {
      final f = await fixture();
      final intent = f.prepare();
      f.socket.incoming.addError(StateError('fixture disconnect'));
      await flushEvents();
      f.health.liveConnected();
      f.health.readSucceeded(synchronizesLiveSnapshot: true);
      await expectLater(f.release(intent), blocked());
      expect(f.writes, isEmpty);
    },
  );

  test(
    'intent expiry is checked synchronously even before expiry timer runs',
    () async {
      final f = await fixture();
      final intent = f.prepare();
      f.now = f.now.add(const Duration(seconds: 30));
      await expectLater(
        f.release(intent),
        blocked(DoorReleaseBlock.intentExpired),
      );
      expect(f.writes, isEmpty);
    },
  );

  test('background and return invalidates confirmation', () async {
    final f = await fixture();
    final intent = f.prepare();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await expectLater(
      f.release(intent),
      blocked(DoorReleaseBlock.intentExpired),
    );
    expect(f.writes, isEmpty);
  });

  test(
    'new confirmation invalidates old one while unrelated updates do not',
    () async {
      final f = await fixture();
      final first = f.prepare();
      final second = f.prepare();
      f.socket.change('light.unrelated', 'on');
      await flushEvents();
      await expectLater(
        f.release(first),
        blocked(DoorReleaseBlock.intentExpired),
      );
      await f.release(second);
      expect(f.writes.length, 1);
    },
  );

  for (final status in [401, 403, 500]) {
    test(
      '$status response is not retried, a spent intent cannot repeat release',
      () async {
        final f = await fixture();
        f.responseCode = status;
        final intent = f.prepare();
        await expectLater(
          f.release(intent),
          throwsA(isA<ActionExecutionException>()),
        );
        await expectLater(
          f.release(intent),
          blocked(DoorReleaseBlock.intentExpired),
        );
        expect(f.writes.length, 1);
        final receipt = f.container
            .read(actionControllerProvider)
            .receipts
            .single;
        expect(
          receipt.status,
          status == 500 ? ActionStatus.unknown : ActionStatus.failed,
        );
      },
    );
  }

  test('timeout is unknown and never automatically retried', () async {
    final f = await fixture();
    f.sendError = TimeoutException('private fixture transport message');
    final intent = f.prepare();
    await expectLater(
      f.release(intent),
      throwsA(isA<ActionExecutionException>()),
    );
    expect(f.writes.length, 1);
    expect(
      f.container.read(actionControllerProvider).receipts.single.status,
      ActionStatus.unknown,
    );
  });

  test(
    'lock code is required and passed only as ephemeral service data',
    () async {
      final station = DoorStation.fromJson({
        ...fixtureStation.toJson(),
        'unlockEntityId': 'lock.front',
      });
      final f = await fixture(station: station, codeRequired: true);
      final intent = f.prepare();
      await expectLater(
        f.release(intent),
        blocked(DoorReleaseBlock.unsupported),
      );
      expect(f.writes, isEmpty);
      await f.release(intent, code: '2468');
      expect(jsonDecode(f.writes.single.body), {
        'entity_id': 'lock.front',
        'code': '2468',
      });
      final receipt = f.container
          .read(actionControllerProvider)
          .receipts
          .single;
      expect(receipt.key.action, 'lock.unlock');
      expect(receipt.toString(), isNot(contains('2468')));
      expect(
        DoorStation.encodeStored(f.store.stations),
        isNot(contains('2468')),
      );
    },
  );

  test(
    'button code and oversized or control-character lock code are rejected',
    () async {
      final f = await fixture();
      await expectLater(
        f.release(f.prepare(), code: '1234'),
        blocked(DoorReleaseBlock.unsupported),
      );
      expect(f.writes, isEmpty);
      final station = DoorStation.fromJson({
        ...fixtureStation.toJson(),
        'unlockEntityId': 'lock.front',
      });
      final lock = await fixture(station: station);
      for (final code in ['1' * 129, '123\n']) {
        await expectLater(
          lock.release(lock.prepare(), code: code),
          blocked(DoorReleaseBlock.unsupported),
        );
      }
      expect(lock.writes, isEmpty);
    },
  );
  test('Direct source retirement invalidates prepared door command even after return', () async {
    final (_, home) = await routinesHome('direct');
    final f = await fixture(home: home);
    final intent = f.prepare();
    final release = f.container.read(doorReleaseActionProvider);
    await home.choose(HomeSource.verifiedCore);
    await home.choose(HomeSource.directLocal);
    await expectLater(release(intent), blocked(DoorReleaseBlock.intentExpired));
    expect(f.writes, isEmpty);
  });

  test(
    'Core source rejects fresh door preparation despite matching old HA state',
    () async {
      final (_, home) = await routinesHome('direct');
      final f = await fixture(home: home);
      final prepare = f.container.read(doorReleaseIntentProvider);
      await home.choose(HomeSource.verifiedCore);
      expect(() => prepare(f.station), blocked(DoorReleaseBlock.intentExpired));
      expect(f.writes, isEmpty);
    },
  );
}
