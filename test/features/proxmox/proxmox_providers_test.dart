// Reproduce configuration invalidation even when Riverpod retains old values.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/data/proxmox_credentials_store.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';

import 'proxmox_transport_security_test.dart'
    show fixtureConfig, authResponse, dataResponse;

class ControlledConnection extends ProxmoxConnection {
  @override
  Future<ProxmoxConfig?> build() async {
    // Retain the source dependency of the actual connection provider.
    ref.watch(directHomeAccessProvider);
    return fixtureConfig;
  }

  void replace(AsyncValue<ProxmoxConfig?> value) => state = value;
}

class MemoryStore extends ProxmoxCredentialsStore {
  int saves = 0;
  ProxmoxConfig? saved;
  @override
  Future<ProxmoxConfig?> read() async => saved;
  @override
  Future<void> clear({bool Function()? isCurrent}) async {
    saved = null;
  }

  @override
  Future<void> save({
    required String host,
    required int port,
    required String username,
    required String realm,
    required String password,
    required bool allowSelfSigned,
    bool Function()? isCurrent,
  }) async {
    saves++;
    saved = ProxmoxConfig(
      host: host,
      port: port,
      username: username,
      realm: realm,
      password: password,
      allowSelfSigned: allowSelfSigned,
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
  test('loading/error closes previous connection and clears evidence; same account settles cleanly', () async {
    final clients = <ProxmoxClient>[];
    final transports = <ClosingTransport>[];
    final container = ProviderContainer(
      overrides: [
        proxmoxConnectionProvider.overrideWith(ControlledConnection.new),
        proxmoxClientFactoryProvider.overrideWithValue((config, health) {
          final transport = ClosingTransport(
            (request) async => request.url.path.endsWith('/access/ticket')
                ? authResponse()
                : dataResponse([]),
          );
          transports.add(transport);
          final client = ProxmoxClient(
            config: config,
            healthSession: health,
            httpClient: transport,
          );
          clients.add(client);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(proxmoxNodesProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(proxmoxConnectionProvider.future);
    await container.pump();
    expect(await container.read(proxmoxNodesProvider.future), isEmpty);
    final monitor = container.read(healthMonitorProvider);
    expect(monitor.read(IntegrationId.proxmox).lastSuccessfulRead, isNotNull);
    final connection = container.read(
      proxmoxConnectionProvider.notifier,
    ) as ControlledConnection;
    connection.replace(
      const AsyncLoading<ProxmoxConfig?>().copyWithPrevious(
        const AsyncData(fixtureConfig),
      ),
    );
    await container.pump();
    expect(await container.read(proxmoxClientProvider.future), isNull);
    expect(clients.single.authCookieValue, isEmpty);
    expect(transports.single.closed, isTrue);
    expect(monitor.read(IntegrationId.proxmox).configured, isFalse);
    expect(monitor.read(IntegrationId.proxmox).lastSuccessfulRead, isNull);
    connection.replace(
      AsyncError<ProxmoxConfig?>(
        StateError('fixture'),
        StackTrace.current,
      ).copyWithPrevious(const AsyncData(fixtureConfig)),
    );
    await container.pump();
    expect(await container.read(proxmoxClientProvider.future), isNull);
    expect(clients.length, 1);
    connection.replace(const AsyncData(fixtureConfig));
    await container.pump();
    expect(await container.read(proxmoxNodesProvider.future), isEmpty);
    expect(clients.length, 2);
    expect(monitor.read(IntegrationId.proxmox).lastSuccessfulRead, isNotNull);
  });
  test(
    'sign-out invalidates delayed sign-in and prevents credential save',
    () async {
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      final store = MemoryStore();
      final container = ProviderContainer(
        overrides: [
          proxmoxCredentialsStoreProvider.overrideWith((_) => store),
          proxmoxClientFactoryProvider.overrideWithValue(
            (config, health) => ProxmoxClient(
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
      final sub = container.listen(proxmoxConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(proxmoxConnectionProvider.future);
      final connection = container.read(proxmoxConnectionProvider.notifier);
      final result = expectLater(
        connection.signIn(
          host: fixtureConfig.host,
          port: 8006,
          username: 'fixture',
          realm: 'pam',
          password: 'fixture',
          allowSelfSigned: false,
        ),
        throwsA(isA<Exception>()),
      );
      await started.future;
      await connection.signOut();
      pending.complete(authResponse());
      await result;
      expect(store.saves, 0);
      expect(store.saved, isNull);
      expect(container.read(proxmoxConnectionProvider).value, isNull);
    },
  );
  test(
    'late previous-account read cannot replace current nodes or health',
    () async {
      final oldRead = Completer<http.Response>();
      final started = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          proxmoxConnectionProvider.overrideWith(ControlledConnection.new),
          proxmoxClientFactoryProvider.overrideWithValue(
            (config, health) => ProxmoxClient(
              config: config,
              healthSession: health,
              httpClient: MockClient((request) async {
                if (request.url.path.endsWith('/access/ticket')) {
                  return authResponse();
                }
                if (config.host == fixtureConfig.host) {
                  started.complete();
                  return oldRead.future;
                }
                return dataResponse([
                  {'node': 'new-node', 'status': 'online'},
                ]);
              }),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(proxmoxNodesProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(proxmoxConnectionProvider.future);
      await container.pump();
      await started.future;
      final connection = container.read(
        proxmoxConnectionProvider.notifier,
      ) as ControlledConnection;
      connection.replace(
        const AsyncData(
          ProxmoxConfig(
            host: 'new-proxmox.test',
            port: 8006,
            username: 'new',
            realm: 'pam',
            password: 'new-fixture',
            allowSelfSigned: false,
          ),
        ),
      );
      await container.pump();
      expect(
        (await container.read(proxmoxNodesProvider.future)).single.name,
        'new-node',
      );
      oldRead.complete(http.Response('old private message', 403));
      await container.pump();
      expect(
        (await container.read(proxmoxNodesProvider.future)).single.name,
        'new-node',
      );
      expect(
        container
            .read(healthMonitorProvider)
            .read(IntegrationId.proxmox)
            .failure,
        isNull,
      );
    },
  );
}
