// Reproduce Riverpod's retained-value loading/error states deterministically.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/media/data/media_api_exception.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_client.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_config.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_credentials_store.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';

const configA = QbittorrentConfig(
  baseUrl: 'http://a.test/proxy',
  username: 'same-user',
  password: 'a-fixture',
);
const configB = QbittorrentConfig(
  baseUrl: 'http://b.test/proxy',
  username: 'same-user',
  password: 'b-fixture',
);

class MemoryStore extends QbittorrentCredentialsStore {
  MemoryStore(this.config);
  QbittorrentConfig? config;
  int saves = 0;
  int clears = 0;
  @override
  Future<QbittorrentConfig?> read() async => config;
  @override
  Future<void> save({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) async {
    saves++;
    config = QbittorrentConfig(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
  }

  @override
  Future<void> clear({bool Function()? isCurrent}) async {
    clears++;
    config = null;
  }
}

class ControlledConnection extends QbittorrentConnection {
  @override
  Future<QbittorrentConfig?> build() async => configA;
  void replace(AsyncValue<QbittorrentConfig?> value) => state = value;
}

class ClosingHttp extends MockClient {
  ClosingHttp(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

http.Response success(http.Request request) {
  if (request.url.path.endsWith('/auth/login')) {
    return http.Response(
      '',
      204,
      headers: {'set-cookie': 'QBT_SID_8080=fixture; Path=/'},
    );
  }
  if (request.url.path.endsWith('/app/version')) {
    return http.Response('v5.2.3', 200);
  }
  if (request.url.path.endsWith('/app/webapiVersion')) {
    return http.Response('2.15.1', 200);
  }
  return http.Response('[]', 200);
}

void main() {
  test(
    'resolved config binds health, authenticates once, and closes on dispose',
    () async {
      final store = MemoryStore(configA);
      var calls = 0;
      final transport = ClosingHttp((request) async {
        calls++;
        return success(request);
      });
      final container = ProviderContainer(
        overrides: [
          qbittorrentCredentialsStoreProvider.overrideWith((_) => store),
          qbittorrentClientFactoryProvider.overrideWithValue(
            (config, health) => QbittorrentClient(
              config: config,
              httpClient: transport,
              healthSession: health,
            ),
          ),
        ],
      );
      final sub = container.listen(qbittorrentTorrentsProvider, (_, _) {});
      await container.read(qbittorrentConnectionProvider.future);
      await container.pump();
      expect(await container.read(qbittorrentTorrentsProvider.future), isEmpty);
      final state = container
          .read(healthMonitorProvider)
          .read(IntegrationId.qbittorrent);
      expect(state.configured, isTrue);
      expect(state.lastSuccessfulRead, isNotNull);
      expect(calls, 4);
      sub.close();
      await container.pump();
      expect(transport.closed, isTrue);
      container.dispose();
    },
  );

  test(
    'loading and errors never instantiate a client from previous credentials',
    () async {
      final clients = <QbittorrentClient>[];
      final container = ProviderContainer(
        overrides: [
          qbittorrentConnectionProvider.overrideWith(ControlledConnection.new),
          qbittorrentClientFactoryProvider.overrideWithValue((config, health) {
            final client = QbittorrentClient(
              config: config,
              healthSession: health,
              httpClient: MockClient((request) async => success(request)),
            );
            clients.add(client);
            return client;
          }),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(qbittorrentClientProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(qbittorrentConnectionProvider.future);
      await container.pump();
      expect(await container.read(qbittorrentClientProvider.future), isNotNull);
      final connection = container.read(
        qbittorrentConnectionProvider.notifier,
      ) as ControlledConnection;
      connection.replace(
        const AsyncLoading<QbittorrentConfig?>().copyWithPrevious(
          const AsyncData(configA),
        ),
      );
      await container.pump();
      expect(await container.read(qbittorrentClientProvider.future), isNull);
      expect(clients.single.isAuthenticated, isFalse);
      connection.replace(
        AsyncError<QbittorrentConfig?>(
          StateError('fixture'),
          StackTrace.current,
        ).copyWithPrevious(const AsyncData(configA)),
      );
      await container.pump();
      expect(await container.read(qbittorrentClientProvider.future), isNull);
      expect(clients, hasLength(1));
    },
  );

  test('replaced account rejects late login and does not taint current read health', () async {
    final oldResponse = Completer<http.Response>();
    final oldStarted = Completer<void>();
    final transports = <String, ClosingHttp>{};
    final container = ProviderContainer(
      overrides: [
        qbittorrentConnectionProvider.overrideWith(ControlledConnection.new),
        qbittorrentClientFactoryProvider.overrideWithValue((config, health) {
          final transport = ClosingHttp((request) async {
            if (config.baseUrl == configA.baseUrl &&
                request.url.path.endsWith('/auth/login')) {
              oldStarted.complete();
              return oldResponse.future;
            }
            return success(request);
          });
          transports[config.baseUrl] = transport;
          return QbittorrentClient(
            config: config,
            httpClient: transport,
            healthSession: health,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(qbittorrentClientProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(qbittorrentConnectionProvider.future);
    await oldStarted.future;
    (container.read(
      qbittorrentConnectionProvider.notifier,
    ) as ControlledConnection).replace(const AsyncData(configB));
    await container.pump();
    final active = await container.read(qbittorrentClientProvider.future);
    expect(active!.isAuthenticated, isTrue);
    expect(transports[configA.baseUrl]!.closed, isTrue);
    oldResponse.complete(http.Response('private fixture', 401));
    await container.pump();
    final health = container
        .read(healthMonitorProvider)
        .read(IntegrationId.qbittorrent);
    expect(health.failure, isNull);
    expect(health.lastSuccessfulRead, isNotNull);
    expect(
      identical(container.read(qbittorrentClientProvider).value, active),
      isTrue,
    );
  });

  test('late sign-in after sign-out never persists credentials', () async {
    final store = MemoryStore(null);
    final pending = Completer<http.Response>();
    final transport = ClosingHttp((request) async => pending.future);
    final container = ProviderContainer(
      overrides: [
        qbittorrentCredentialsStoreProvider.overrideWith((_) => store),
        qbittorrentClientFactoryProvider.overrideWithValue(
          (config, health) =>
              QbittorrentClient(config: config, httpClient: transport),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(qbittorrentConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(qbittorrentConnectionProvider.future);
    final notifier = container.read(qbittorrentConnectionProvider.notifier);
    final login = notifier.signIn(
      baseUrl: configA.baseUrl,
      username: configA.username,
      password: configA.password,
    );
    final rejected = expectLater(login, throwsA(isA<MediaApiException>()));
    await notifier.signOut();
    pending.complete(
      http.Response('', 204, headers: {'set-cookie': 'SID=fixture; Path=/'}),
    );
    await rejected;
    expect(transport.closed, isTrue);
    expect(store.saves, 0);
    expect(store.clears, 1);
    expect(store.config, isNull);
    expect(container.read(qbittorrentConnectionProvider).value, isNull);
  });

  test('overlapping sign-in for the same account persists only the latest credentials', () async {
    final store = MemoryStore(null);
    final oldResponse = Completer<http.Response>();
    final transports = <ClosingHttp>[];
    final container = ProviderContainer(
      overrides: [
        qbittorrentCredentialsStoreProvider.overrideWith((_) => store),
        qbittorrentClientFactoryProvider.overrideWithValue((config, health) {
          final isOld = transports.isEmpty;
          final transport = ClosingHttp(
            (request) async => isOld ? oldResponse.future : success(request),
          );
          transports.add(transport);
          return QbittorrentClient(config: config, httpClient: transport);
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(qbittorrentConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(qbittorrentConnectionProvider.future);
    final notifier = container.read(qbittorrentConnectionProvider.notifier);
    final oldLogin = notifier.signIn(
      baseUrl: configA.baseUrl,
      username: configA.username,
      password: 'old-fixture',
    );
    final rejected = expectLater(oldLogin, throwsA(isA<MediaApiException>()));
    await notifier.signIn(
      baseUrl: configA.baseUrl,
      username: configA.username,
      password: 'new-fixture',
    );
    oldResponse.complete(
      http.Response('', 204, headers: {'set-cookie': 'SID=old; Path=/'}),
    );
    await rejected;
    expect(store.saves, 1);
    expect(store.config!.password, 'new-fixture');
    expect(
      container.read(qbittorrentConnectionProvider).value!.password,
      'new-fixture',
    );
    expect(transports.every((transport) => transport.closed), isTrue);
  });

  test('provider does not automatically retry rejected login', () async {
    var logins = 0;
    final transports = <ClosingHttp>[];
    final container = ProviderContainer(
      overrides: [
        qbittorrentCredentialsStoreProvider.overrideWith(
          (_) => MemoryStore(configA),
        ),
        qbittorrentClientFactoryProvider.overrideWithValue((config, health) {
          final transport = ClosingHttp((request) async {
            logins++;
            return http.Response('', 401);
          });
          transports.add(transport);
          return QbittorrentClient(
            config: config,
            httpClient: transport,
            healthSession: health,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(qbittorrentClientProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(qbittorrentConnectionProvider.future);
    await container.pump();
    await expectLater(
      container.read(qbittorrentClientProvider.future),
      throwsA(isA<MediaApiException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(logins, 1);
    expect(transports.single.closed, isTrue);
    expect(
      container
          .read(healthMonitorProvider)
          .read(IntegrationId.qbittorrent)
          .failure,
      HealthFailure.authentication,
    );
  });
}
