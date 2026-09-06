// Synthesize retained configuration states, including Riverpod's previous value.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/data/keenetic_credentials_store.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/keenetic/providers/keenetic_telemetry_providers.dart';

import 'keenetic_telemetry_test.dart' show fixtureConfig, telemetryResponse;

class ControlledConnection extends KeeneticConnection {
  @override
  Future<KeeneticConfig?> build() async => fixtureConfig;
  void replace(AsyncValue<KeeneticConfig?> value) => state = value;
}

class MemoryStore extends KeeneticCredentialsStore {
  KeeneticConfig? saved;
  int saves = 0;
  @override
  Future<KeeneticConfig?> read() async => saved;
  @override
  Future<void> clear({bool Function()? isCurrent}) async {
    saved = null;
  }

  @override
  Future<void> save({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) async {
    saves++;
    saved = KeeneticConfig(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
  }
}

class ClosingTransport extends MockClient {
  ClosingTransport(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('retained loading/error config closes old client and clears health; same account settles afresh', () async {
    final transports = <ClosingTransport>[];
    final container = ProviderContainer(
      overrides: [
        keeneticConnectionProvider.overrideWith(ControlledConnection.new),
        keeneticClientFactoryProvider.overrideWithValue((config, health) {
          final transport = ClosingTransport(
            (request) async => request.url.path.endsWith('/auth')
                ? http.Response(
                    '',
                    200,
                    headers: {'set-cookie': 'session=fixture; Path=/'},
                  )
                : http.Response('{"host":[]}', 200),
          );
          transports.add(transport);
          return KeeneticClient(
            config: config,
            healthSession: health,
            httpClient: transport,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(keeneticDevicesProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(keeneticConnectionProvider.future);
    await container.pump();
    expect(await container.read(keeneticDevicesProvider.future), isEmpty);
    final monitor = container.read(healthMonitorProvider);
    expect(monitor.read(IntegrationId.keenetic).lastSuccessfulRead, isNotNull);
    final connection = container.read(
      keeneticConnectionProvider.notifier,
    ) as ControlledConnection;
    connection.replace(
      const AsyncLoading<KeeneticConfig?>().copyWithPrevious(
        const AsyncData(fixtureConfig),
      ),
    );
    await container.pump();
    expect(await container.read(keeneticClientProvider.future), isNull);
    expect(transports.single.closed, isTrue);
    expect(monitor.read(IntegrationId.keenetic).configured, isFalse);
    expect(monitor.read(IntegrationId.keenetic).lastSuccessfulRead, isNull);
    connection.replace(
      AsyncError<KeeneticConfig?>(
        StateError('fixture'),
        StackTrace.current,
      ).copyWithPrevious(const AsyncData(fixtureConfig)),
    );
    await container.pump();
    expect(await container.read(keeneticClientProvider.future), isNull);
    expect(transports.length, 1);
    connection.replace(const AsyncData(fixtureConfig));
    await container.pump();
    expect(await container.read(keeneticDevicesProvider.future), isEmpty);
    expect(transports.length, 2);
    expect(monitor.read(IntegrationId.keenetic).lastSuccessfulRead, isNotNull);
  });

  test(
    'sign-out prevents delayed verification from saving credentials',
    () async {
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      final store = MemoryStore();
      final container = ProviderContainer(
        overrides: [
          keeneticCredentialsStoreProvider.overrideWith((_) => store),
          keeneticClientFactoryProvider.overrideWithValue(
            (config, health) => KeeneticClient(
              config: config,
              httpClient: MockClient((_) {
                started.complete();
                return pending.future;
              }),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(keeneticConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(keeneticConnectionProvider.future);
      final connection = container.read(keeneticConnectionProvider.notifier);
      final signIn = connection.signIn(
        baseUrl: fixtureConfig.baseUrl,
        username: 'fixture',
        password: 'fixture',
      );
      final observed = expectLater(signIn, throwsA(isA<Exception>()));
      await started.future;
      await connection.signOut();
      pending.complete(http.Response('', 200));
      await observed;
      expect(store.saves, 0);
      expect(store.saved, isNull);
      expect(container.read(keeneticConnectionProvider).value, isNull);
    },
  );

  testWidgets(
    'telemetry controller creation performs no login, and account replacement rejects old results',
    (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final transports = <ClosingTransport>[];
      final container = ProviderContainer(
        overrides: [
          keeneticConnectionProvider.overrideWith(ControlledConnection.new),
          keeneticClientFactoryProvider.overrideWithValue((config, health) {
            final transport = ClosingTransport((request) async {
              calls++;
              if (config.username == 'fixture' &&
                  !request.url.path.endsWith('/auth')) {
                return pending.future;
              }
              return telemetryResponse(request);
            });
            transports.add(transport);
            return KeeneticClient(
              config: config,
              healthSession: health,
              httpClient: transport,
            );
          }),
        ],
      );
      final scopeSub = container.listen(
        keeneticTelemetryControllerProvider,
        (_, _) {},
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(calls, 0);
      final metric = keeneticMetricProvider(
        const KeeneticMetricRequest(KeeneticMetricKind.internetStatus),
      );
      final metricSub = container.listen(metric, (_, _) {});
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      final before = container
          .read(keeneticTelemetryControllerProvider)
          .snapshot
          .accountGeneration;
      final connection = container.read(
        keeneticConnectionProvider.notifier,
      ) as ControlledConnection;
      connection.replace(
        const AsyncData(
          KeeneticConfig(
            baseUrl: 'http://new-router.test/proxy',
            username: 'new',
            password: 'new-fixture',
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      // A visible widget reads the invalidated provider during its next build.
      container.read(metric);
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      pending.complete(http.Response('private old response', 403));
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      final result = container
          .read(keeneticTelemetryControllerProvider)
          .snapshot;
      expect(identical(before, result.accountGeneration), isFalse);
      expect(transports.first.closed, isTrue);
      expect(
        result.internet.succeeded,
        isTrue,
        reason:
            'calls=$calls transports=${transports.length} refreshing=${result.isRefreshing} issue=${result.internet.issue} connection=${result.connectionIssue} provider=${container.read(metric)}',
      );
      expect(
        container
            .read(healthMonitorProvider)
            .read(IntegrationId.keenetic)
            .failure,
        isNull,
      );
      metricSub.close();
      scopeSub.close();
      container.dispose();
      await tester.pump();
    },
  );
}
