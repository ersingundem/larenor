import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:qbittorrent_api/qbittorrent_api.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/configuration_writes.dart';
import '../../../health/data/health_monitor.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/providers/health_providers.dart';
import '../../data/media_api_exception.dart';
import '../data/qbittorrent_client.dart';
import '../data/qbittorrent_config.dart';
import '../data/qbittorrent_credentials_store.dart';

part 'qbittorrent_providers.g.dart';

typedef QbittorrentClientFactory = QbittorrentClient Function(
  QbittorrentConfig config,
  HealthSession? health,
);

/// Injectable transport boundary; credentials and cookies are never emitted.
final qbittorrentClientFactoryProvider = Provider<QbittorrentClientFactory>(
  (ref) =>
      (config, health) =>
          QbittorrentClient(config: config, healthSession: health),
);

@riverpod
QbittorrentCredentialsStore qbittorrentCredentialsStore(Ref ref) =>
    QbittorrentCredentialsStore();

@riverpod
class QbittorrentConnection extends _$QbittorrentConnection {
  int _generation = 0;
  QbittorrentClient? _verificationClient;

  @override
  Future<QbittorrentConfig?> build() {
    ref.onDispose(() {
      _generation++;
      _verificationClient?.dispose();
    });
    return ref.watch(qbittorrentCredentialsStoreProvider).read();
  }

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final previous = state.value;
    final generation = ++_generation;
    _verificationClient?.dispose();
    state = const AsyncLoading();
    final config = QbittorrentConfig(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
    QbittorrentClient? client;
    bool current() => ref.mounted && _generation == generation;
    try {
      client = ref.read(qbittorrentClientFactoryProvider)(config, null);
      _verificationClient = client;
      await client.login();
      await ConfigurationWrites.run(() async {
        if (!current()) return;
        await ref
            .read(qbittorrentCredentialsStoreProvider)
            .save(baseUrl: baseUrl, username: username, password: password);
        if (current()) state = AsyncData(config);
      });
    } catch (_) {
      if (current()) state = AsyncData(previous);
      throw MediaApiException('Could not sign in — check URL and credentials.');
    } finally {
      client?.dispose();
      if (identical(_verificationClient, client)) _verificationClient = null;
    }
  }

  Future<void> signOut() async {
    final generation = ++_generation;
    _verificationClient?.dispose();
    state = const AsyncLoading();
    await ConfigurationWrites.run(() async {
      if (!ref.mounted || generation != _generation) return;
      await ref.read(qbittorrentCredentialsStoreProvider).clear();
      if (ref.mounted && generation == _generation) {
        state = const AsyncData(null);
      }
    });
  }
}

// Session acquisition and writes must never be automatically retried by Riverpod.
@Riverpod(retry: _noRetry)
Future<QbittorrentClient?> qbittorrentClient(Ref ref) async {
  final connection = ref.watch(qbittorrentConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final health = ref
      .watch(healthMonitorProvider)
      .bind(
        IntegrationId.qbittorrent,
        configured: config != null,
        configurationIdentity: config,
      );
  ref.onDispose(health.close);
  if (config == null) return null;
  final client = ref.watch(qbittorrentClientFactoryProvider)(config, health);
  ref.onDispose(client.dispose);
  try {
    await client.login();
    if (!ref.mounted) {
      client.dispose();
      return null;
    }
    return client;
  } catch (_) {
    client.dispose();
    rethrow;
  }
}

@Riverpod(retry: _noRetry)
Future<List<TorrentInfo>> qbittorrentTorrents(Ref ref) async {
  final client = await ref.watch(qbittorrentClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.torrents.getTorrentsList();
}

Duration? _noRetry(int retryCount, Object error) => null;
