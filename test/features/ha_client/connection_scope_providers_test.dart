// Reproduce Riverpod's retained-value loading/error states deterministically.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_health_bindings.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';

import 'fake_socket.dart';

const _config = HaConnectionConfig(baseUrl: 'http://ha.test', token: 'fixture');
const _newConfig = HaConnectionConfig(
  baseUrl: 'http://other.test',
  token: 'new-fixture',
);

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => _config;
  void replace(AsyncValue<HaConnectionConfig?> value) => state = value;
}

class _Http extends MockClient {
  _Http(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _Fixture {
  _Fixture({Future<http.Response> Function(HaConnectionConfig)? read}) {
    container = ProviderContainer(
      overrides: [
        connectionConfigProvider.overrideWith(_Connection.new),
        healthMonitorProvider.overrideWithValue(monitor),
        haRestClientFactoryProvider.overrideWithValue((config, health) {
          final httpClient = _Http(
            (_) async => read != null ? read(config) : _states(config),
          );
          transports.add(httpClient);
          final client = HaRestClient(
            baseUrl: config.baseUrl,
            token: config.token,
            healthSession: health,
            observer: health.observeTransport,
            httpClient: httpClient,
          );
          rests.add(client);
          return client;
        }),
        haWebSocketClientFactoryProvider.overrideWithValue((config, health) {
          final socket = FakeSocket();
          sockets.add(socket);
          return HaWebSocketClient(
            baseUrl: config.baseUrl,
            token: config.token,
            channelFactory: (_) => socket,
            connectionObserver: (event) => observeHaConnection(health, event),
          );
        }),
      ],
    );
    container.listen(haRestClientProvider, (_, _) {});
    container.listen(haWebSocketClientProvider, (_, _) {});
    container.listen(haHealthSessionProvider, (_, _) {});
  }
  final monitor = HealthMonitor();
  late final ProviderContainer container;
  final transports = <_Http>[];
  final rests = <HaRestClient>[];
  final sockets = <FakeSocket>[];
  _Connection get connection =>
      container.read(connectionConfigProvider.notifier) as _Connection;
  IntegrationHealth get health => monitor.read(IntegrationId.ha);

  Future<void> ready() async {
    await container.read(connectionConfigProvider.future);
    await container.pump();
    await sockets.last.authenticate();
  }

  Future<void> dispose() async {
    container.dispose();
    monitor.dispose();
    for (final socket in sockets) {
      await socket.incoming.close();
    }
  }
}

http.Response _states(HaConnectionConfig config) => http.Response(
  jsonEncode([
    {
      'entity_id': 'light.lamp',
      'state': config.baseUrl == _config.baseUrl ? 'off' : 'on',
    },
  ]),
  200,
);

void main() {
  for (final loading in [true, false]) {
    test(
      '${loading ? 'loading' : 'error'} with previous config closes both clients and clears evidence; same account recovers',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        await fixture.ready();
        final container = fixture.container;
        final oldRest = container.read(haRestClientProvider)!;
        final oldWs = container.read(haWebSocketClientProvider)!;
        final oldHealth = container.read(haHealthSessionProvider);
        oldHealth.readSucceeded(synchronizesLiveSnapshot: true);
        expect(fixture.health.lastSuccessfulRead, isNotNull);
        expect(fixture.health.liveUpdates, isTrue);

        final AsyncValue<HaConnectionConfig?> unresolved = loading
            ? const AsyncLoading<HaConnectionConfig?>().copyWithPrevious(
                const AsyncData(_config),
              )
            : AsyncError<HaConnectionConfig?>(
                StateError('storage unavailable'),
                StackTrace.current,
              ).copyWithPrevious(const AsyncData(_config));
        expect(unresolved.value, same(_config));
        fixture.connection.replace(unresolved);
        await container.pump();
        expect(container.read(haRestClientProvider), isNull);
        expect(container.read(haWebSocketClientProvider), isNull);
        expect(fixture.transports.single.closed, isTrue);
        expect(fixture.sockets.single.closed, isTrue);
        expect(fixture.health.configured, isFalse);
        expect(fixture.health.lastSuccessfulRead, isNull);
        expect(fixture.health.liveUpdates, isFalse);

        // Late callbacks from the discarded session cannot establish proof.
        oldHealth.readSucceeded(synchronizesLiveSnapshot: true);
        oldHealth.liveConnected();
        oldHealth.failed(HealthFailure.authentication);
        expect(fixture.health.lastSuccessfulRead, isNull);
        expect(fixture.health.failure, isNull);
        await container.pump();
        expect(fixture.rests, hasLength(1));
        expect(fixture.sockets, hasLength(1));

        fixture.connection.replace(
          const AsyncData(
            HaConnectionConfig(baseUrl: 'http://ha.test', token: 'fixture'),
          ),
        );
        await container.pump();
        expect(fixture.rests, hasLength(2));
        expect(fixture.sockets, hasLength(2));
        expect(container.read(haRestClientProvider), isNot(same(oldRest)));
        expect(container.read(haWebSocketClientProvider), isNot(same(oldWs)));
        expect(fixture.health.configured, isTrue);
        expect(fixture.health.lastSuccessfulRead, isNull);
        await fixture.sockets.last.authenticate();
        container.listen(entitiesProvider, (_, _) {});
        expect(
          (await container.read(entitiesProvider.future))['light.lamp']!.state,
          'off',
        );
        expect(fixture.health.lastSuccessfulRead, isNotNull);
        expect(fixture.health.failure, isNull);
      },
    );
  }

  test('late old-account REST read after loading and replacement cannot publish data or health', () async {
    final lateRead = Completer<http.Response>();
    final readStarted = Completer<void>();
    final fixture = _Fixture(
      read: (config) {
        if (config.baseUrl == _config.baseUrl) {
          if (!readStarted.isCompleted) readStarted.complete();
          return lateRead.future;
        }
        return Future.value(_states(config));
      },
    );
    addTearDown(fixture.dispose);
    await fixture.ready();
    final container = fixture.container;
    container.listen(entitiesProvider, (_, _) {});
    await readStarted.future;
    fixture.connection.replace(
      const AsyncLoading<HaConnectionConfig?>().copyWithPrevious(
        const AsyncData(_config),
      ),
    );
    await container.pump();
    expect(await container.read(entitiesProvider.future), isEmpty);
    expect(fixture.health.lastSuccessfulRead, isNull);
    fixture.connection.replace(const AsyncData(_newConfig));
    await container.pump();
    await fixture.sockets.last.authenticate();
    expect(
      (await container.read(entitiesProvider.future))['light.lamp']!.state,
      'on',
    );
    final successfulAt = fixture.health.lastSuccessfulRead;
    lateRead.complete(http.Response('private old response', 401));
    await flushEvents();
    await container.pump();
    expect(container.read(entitiesProvider).value!['light.lamp']!.state, 'on');
    expect(fixture.health.lastSuccessfulRead, successfulAt);
    expect(fixture.health.failure, isNull);
    expect(fixture.transports.first.closed, isTrue);
    expect(fixture.sockets.first.closed, isTrue);
  });
}
