import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/direct_home_access.dart';

import '../data/prowlarr_client.dart';
import '../data/prowlarr_config.dart';
import '../data/prowlarr_credentials_store.dart';
import '../data/models/prowlarr_indexer.dart';

part 'prowlarr_providers.g.dart';

@riverpod
ProwlarrCredentialsStore prowlarrCredentialsStore(Ref ref) =>
    ProwlarrCredentialsStore(access: ref.watch(directHomeAccessProvider));

@riverpod
class ProwlarrConnection extends _$ProwlarrConnection {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  int _operation = 0;
  ProwlarrClient? _checkingClient;

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
  Future<ProwlarrConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    final operation = ++_operation;
    ref.onDispose(() {
      _operation++;
      _closeCheck();
    });
    _check(operation);
    final result = await ref.watch(prowlarrCredentialsStoreProvider).read();
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
    final store = ref.read(prowlarrCredentialsStoreProvider);
    final config = ProwlarrConfig(baseUrl: baseUrl, apiKey: apiKey);
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
    } catch (_) {
      _check(operation);
      rethrow;
    } finally {
      if (identical(_checkingClient, client)) _closeCheck();
    }
  }

  Future<void> signOut() async {
    _check();
    final operation = ++_operation;
    final store = ref.read(prowlarrCredentialsStoreProvider);
    _closeCheck();
    await store.clear();
    _check(operation);
    state = const AsyncData(null);
  }

  ProwlarrClient _client(ProwlarrConfig config) => ProwlarrClient(config: config);
}

@riverpod
ProwlarrClient? prowlarrClient(Ref ref) {
  final access = ref.watch(directHomeAccessProvider);
  if (!access.isCurrent) return null;
  final connection = ref.watch(prowlarrConnectionProvider);
  final config = connection.isLoading || connection.hasError ? null : connection.value;
  if (config == null) return null;
  final client = ProwlarrClient(config: config);
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<ProwlarrIndexer>> prowlarrIndexers(Ref ref) async {
  final client = ref.watch(prowlarrClientProvider);
  if (client == null) return [];
  return client.getIndexers();
}
