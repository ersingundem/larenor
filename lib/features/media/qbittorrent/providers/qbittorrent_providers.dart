import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:qbittorrent_api/qbittorrent_api.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/direct_home_access.dart';
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
    QbittorrentCredentialsStore(access: ref.watch(directHomeAccessProvider));

@riverpod
class QbittorrentConnection extends _$QbittorrentConnection {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  int _generation = 0;
  QbittorrentClient? _verificationClient;
  bool Function()? _verificationOwner;
  int? _verificationGeneration;

  void _check([int? generation]) {
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    _access.check();
    if (generation != null && generation != _generation) {
      throw MediaApiException('Connection is no longer active.');
    }
  }

  void _closeCheck() {
    _verificationClient?.dispose();
    _verificationClient = null;
    _verificationOwner = null;
    _verificationGeneration = null;
  }

  /// Cancels only this form's current verification transport. This performs no
  /// storage, normal reader login, retry or rollback of an already sent request.
  void cancelSignIn(bool Function() owner) {
    if (identical(_verificationOwner, owner) &&
        _verificationGeneration == _generation) {
      _verificationClient?.dispose();
    }
  }

  @override
  Future<QbittorrentConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    final generation = ++_generation;
    ref.onDispose(() {
      _generation++;
      _closeCheck();
    });
    _check(generation);
    final value = await ref.watch(qbittorrentCredentialsStoreProvider).read();
    _check(generation);
    return value;
  }

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) async {
    void checkAction() {
      try {
        if (isCurrent == null || isCurrent()) return;
      } catch (_) {}
      throw const DirectHomeAccessException('unavailable');
    }

    _check();
    checkAction();
    final previous = state;
    final generation = ++_generation;
    final store = ref.read(qbittorrentCredentialsStoreProvider);
    final factory = ref.read(qbittorrentClientFactoryProvider);
    _closeCheck();
    // Keep an empty/pending setup form alive while its own action verifies.
    // A previously usable reader must still retire before account replacement.
    if (!previous.isLoading && !previous.hasError && previous.value != null) {
      state = const AsyncLoading();
    }
    final config = QbittorrentConfig(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
    QbittorrentClient? client;
    bool current() =>
        ref.mounted && _access.isCurrent && _generation == generation;
    bool actionCurrent() {
      if (!current()) return false;
      try {
        return isCurrent == null || isCurrent();
      } catch (_) {
        return false;
      }
    }

    try {
      client = factory(config, null);
      _verificationClient = client;
      _verificationOwner = isCurrent;
      _verificationGeneration = generation;
      await client.login();
      _check(generation);
      checkAction();
      await store.save(
        baseUrl: baseUrl,
        username: username,
        password: password,
        isCurrent: actionCurrent,
      );
      _check(generation);
      checkAction();
      state = AsyncData(config);
    } catch (error) {
      _check(generation);
      try {
        checkAction();
      } on DirectHomeAccessException catch (expired) {
        state = AsyncError(expired, StackTrace.empty);
        rethrow;
      }
      // A possibly persisted partial tuple must never republish a usable
      // connection. Its private marker requires explicit complete recovery.
      if (error is DirectHomeAccessException) {
        state = AsyncError(error, StackTrace.empty);
        rethrow;
      }
      if (current()) {
        state = previous.isLoading
            ? AsyncError(
                const DirectHomeAccessException('unavailable'),
                StackTrace.empty,
              )
            : previous;
      }
      throw MediaApiException('Could not sign in — check URL and credentials.');
    } finally {
      client?.dispose();
      if (identical(_verificationClient, client)) {
        _verificationClient = null;
        _verificationOwner = null;
        _verificationGeneration = null;
      }
    }
  }

  Future<void> signOut() async {
    _check();
    final generation = ++_generation;
    final store = ref.read(qbittorrentCredentialsStoreProvider);
    _closeCheck();
    state = const AsyncLoading();
    try {
      await store.clear(
        isCurrent: () =>
            ref.mounted && _access.isCurrent && generation == _generation,
      );
      _check(generation);
      state = const AsyncData(null);
    } catch (error) {
      _check(generation);
      state = AsyncError(
        const DirectHomeAccessException('write_unconfirmed'),
        StackTrace.empty,
      );
      rethrow;
    }
  }
}

// Session acquisition and writes must never be automatically retried by Riverpod.
@Riverpod(retry: _noRetry)
Future<QbittorrentClient?> qbittorrentClient(Ref ref) async {
  final access = ref.watch(directHomeAccessProvider);
  access.check();
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
    access.check();
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
