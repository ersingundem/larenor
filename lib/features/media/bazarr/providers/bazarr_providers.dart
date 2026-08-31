import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/bazarr_client.dart';
import '../data/bazarr_config.dart';
import '../data/bazarr_credentials_store.dart';
import '../data/models/bazarr_wanted_item.dart';

part 'bazarr_providers.g.dart';

@riverpod
BazarrCredentialsStore bazarrCredentialsStore(Ref ref) =>
    BazarrCredentialsStore();

@riverpod
class BazarrConnection extends _$BazarrConnection {
  @override
  Future<BazarrConfig?> build() =>
      ref.watch(bazarrCredentialsStoreProvider).read();

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    final config = BazarrConfig(baseUrl: baseUrl, apiKey: apiKey);
    await BazarrClient(config: config).checkConnection();
    await ref
        .read(bazarrCredentialsStoreProvider)
        .save(baseUrl: baseUrl, apiKey: apiKey);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(bazarrCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }
}

@riverpod
BazarrClient? bazarrClient(Ref ref) {
  final config = ref.watch(bazarrConnectionProvider).value;
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
