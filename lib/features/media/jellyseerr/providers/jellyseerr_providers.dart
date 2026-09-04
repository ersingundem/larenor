import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../health/data/integration_health.dart';
import '../../../health/providers/health_providers.dart';

import '../data/jellyseerr_client.dart';
import '../data/jellyseerr_config.dart';
import '../data/jellyseerr_credentials_store.dart';
import '../data/models/jellyseerr_request_item.dart';

part 'jellyseerr_providers.g.dart';

@riverpod
JellyseerrCredentialsStore jellyseerrCredentialsStore(Ref ref) =>
    JellyseerrCredentialsStore();

@riverpod
class JellyseerrConnection extends _$JellyseerrConnection {
  @override
  Future<JellyseerrConfig?> build() =>
      ref.watch(jellyseerrCredentialsStoreProvider).read();

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    final config = JellyseerrConfig(baseUrl: baseUrl, apiKey: apiKey);
    await JellyseerrClient(config: config).checkConnection();
    await ref
        .read(jellyseerrCredentialsStoreProvider)
        .save(baseUrl: baseUrl, apiKey: apiKey);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(jellyseerrCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }
}

@riverpod
JellyseerrClient? jellyseerrClient(Ref ref) {
  final config = ref.watch(jellyseerrConnectionProvider).value;
  final health = ref
      .watch(healthMonitorProvider)
      .bind(IntegrationId.jellyseerr, configured: config != null);
  ref.onDispose(health.close);
  if (config == null) return null;
  final client = JellyseerrClient(config: config, healthSession: health);
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<JellyseerrRequestItem>> jellyseerrMyRequests(Ref ref) async {
  final client = ref.watch(jellyseerrClientProvider);
  if (client == null) return [];
  return client.myRequests();
}
