import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/direct_home_access.dart';

import '../data/bazarr_client.dart';
import '../data/bazarr_config.dart';
import '../data/bazarr_credentials_store.dart';
import '../data/models/bazarr_wanted_item.dart';

part 'bazarr_providers.g.dart';

@riverpod
BazarrCredentialsStore bazarrCredentialsStore(Ref ref) =>
    BazarrCredentialsStore(access: ref.watch(directHomeAccessProvider));

@riverpod
class BazarrConnection extends _$BazarrConnection {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  int _operation = 0;
  BazarrClient? _checkingClient;

  void _check([int? operation]) {
    if (!ref.mounted || operation != null && operation != _operation) {
      throw const DirectHomeAccessException('unavailable');
    }
    _access.check();
  }

  void _closeCheck() {
    _checkingClient?.dispose();
    _checkingClient = null;
  }

  @override
  Future<BazarrConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    final operation = ++_operation;
    ref.onDispose(() {
      _operation++;
      _closeCheck();
    });
    _check(operation);
    final result = await ref.watch(bazarrCredentialsStoreProvider).read();
    _check(operation);
    return result;
  }

  Future<void> signIn({
    required String baseUrl,
    required String apiKey,
    bool Function()? isCurrent,
  }) async {
    void checkAction() {
      try {
        if (isCurrent == null || isCurrent()) return;
      } catch (_) {}
      throw const DirectHomeAccessException('unavailable');
    }

    checkAction();
    _check();
    if (_checkingClient != null) throw const DirectHomeAccessException('busy');
    final operation = ++_operation;
    final store = ref.read(bazarrCredentialsStoreProvider);
    final config = BazarrConfig(baseUrl: baseUrl, apiKey: apiKey);
    final client = _client(config);
    _checkingClient = client;
    try {
      await client.checkConnection();
      _check(operation);
      checkAction();
      await store.save(baseUrl: baseUrl, apiKey: apiKey, isCurrent: isCurrent);
      _check(operation);
      checkAction();
      state = AsyncData(config);
    } catch (error, stack) {
      _recordFailure(operation, error, stack);
      rethrow;
    } finally {
      if (identical(_checkingClient, client)) _closeCheck();
    }
  }

  Future<void> signOut() async {
    _check();
    final operation = ++_operation;
    final store = ref.read(bazarrCredentialsStoreProvider);
    _closeCheck();
    try {
      await store.clear();
      _check(operation);
      state = const AsyncData(null);
    } catch (error, stack) {
      _recordFailure(operation, error, stack);
      rethrow;
    }
  }

  void _recordFailure(int operation, Object error, StackTrace stack) {
    // An old action must not publish a failure into a newer source or login.
    _check(operation);
    if (error is DirectHomeAccessException &&
        const {
          'write_unconfirmed',
          'pending_mutation',
          'storage_failed',
        }.contains(error.code)) {
      state = AsyncError(error, stack);
    }
  }

  BazarrClient _client(BazarrConfig config) => BazarrClient(config: config);
}

@riverpod
BazarrClient? bazarrClient(Ref ref) {
  final access = ref.watch(directHomeAccessProvider);
  if (!access.isCurrent) return null;
  final connection = ref.watch(bazarrConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  if (config == null) return null;
  final client = BazarrClient(config: config);
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<BazarrWantedItem>> bazarrMissingMovies(Ref ref) async {
  final client = ref.watch(bazarrClientProvider);
  if (client == null) return [];
  return client.getMissingMovieSubtitles();
}

@riverpod
Future<List<BazarrWantedItem>> bazarrMissingEpisodes(Ref ref) async {
  final client = ref.watch(bazarrClientProvider);
  if (client == null) return [];
  return client.getMissingEpisodeSubtitles();
}
