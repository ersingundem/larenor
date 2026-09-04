import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../health/data/integration_health.dart';
import '../../../health/providers/health_providers.dart';

import '../data/jellyfin_client.dart';
import '../data/jellyfin_config.dart';
import '../data/jellyfin_credentials_store.dart';
import '../data/models/jellyfin_item.dart';

part 'jellyfin_providers.g.dart';

@riverpod
JellyfinCredentialsStore jellyfinCredentialsStore(Ref ref) =>
    JellyfinCredentialsStore();

@riverpod
class JellyfinConnection extends _$JellyfinConnection {
  @override
  Future<JellyfinConfig?> build() =>
      ref.watch(jellyfinCredentialsStoreProvider).read();

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final store = ref.read(jellyfinCredentialsStoreProvider);
    final config = await JellyfinClient.login(
      baseUrl: baseUrl,
      username: username,
      password: password,
      deviceId: await store.deviceId(),
    );
    await store.save(
      baseUrl: config.baseUrl,
      userId: config.userId,
      accessToken: config.accessToken,
    );
    state = AsyncData(await store.read());
  }

  Future<void> signOut() async {
    await ref.read(jellyfinCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }
}

@riverpod
JellyfinClient? jellyfinClient(Ref ref) {
  final config = ref.watch(jellyfinConnectionProvider).value;
  final health = ref
      .watch(healthMonitorProvider)
      .bind(IntegrationId.jellyfin, configured: config != null);
  ref.onDispose(health.close);
  if (config == null) return null;
  final client = JellyfinClient(config: config, healthSession: health);
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<JellyfinItem>> jellyfinResumeItems(Ref ref) async {
  final client = ref.watch(jellyfinClientProvider);
  if (client == null) return [];
  return client.getResumeItems();
}

@riverpod
Future<List<JellyfinItem>> jellyfinLatestItems(Ref ref) async {
  final client = ref.watch(jellyfinClientProvider);
  if (client == null) return [];
  return client.getLatestItems();
}

@riverpod
Future<List<JellyfinItem>> jellyfinLibraries(Ref ref) async {
  final client = ref.watch(jellyfinClientProvider);
  if (client == null) return [];
  return client.getLibraries();
}

@riverpod
Future<List<JellyfinItem>> jellyfinLibraryItems(
  Ref ref,
  String parentId,
) async {
  final client = ref.watch(jellyfinClientProvider);
  if (client == null) return [];
  return client.getItemsInLibrary(parentId);
}
