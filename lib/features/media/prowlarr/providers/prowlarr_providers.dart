import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/prowlarr_client.dart';
import '../data/prowlarr_config.dart';
import '../data/prowlarr_credentials_store.dart';
import '../data/models/prowlarr_indexer.dart';

part 'prowlarr_providers.g.dart';

@riverpod
ProwlarrCredentialsStore prowlarrCredentialsStore(Ref ref) =>
    ProwlarrCredentialsStore();

@riverpod
class ProwlarrConnection extends _$ProwlarrConnection {
  @override
  Future<ProwlarrConfig?> build() =>
      ref.watch(prowlarrCredentialsStoreProvider).read();

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    final config = ProwlarrConfig(baseUrl: baseUrl, apiKey: apiKey);
    await ProwlarrClient(config: config).checkConnection();
    await ref
        .read(prowlarrCredentialsStoreProvider)
        .save(baseUrl: baseUrl, apiKey: apiKey);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(prowlarrCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }
}

@riverpod
ProwlarrClient? prowlarrClient(Ref ref) {
  final config = ref.watch(prowlarrConnectionProvider).value;
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
