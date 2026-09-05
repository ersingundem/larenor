import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/direct_home_access.dart';

import '../../../health/data/integration_health.dart';
import '../../../health/providers/health_providers.dart';

import '../../data/media_api_exception.dart';
import '../data/jellyseerr_client.dart';
import '../data/jellyseerr_config.dart';
import '../data/jellyseerr_credentials_store.dart';
import '../data/models/jellyseerr_request_item.dart';

part 'jellyseerr_providers.g.dart';

@riverpod
JellyseerrCredentialsStore jellyseerrCredentialsStore(Ref ref) =>
    JellyseerrCredentialsStore(access: ref.watch(directHomeAccessProvider));

@riverpod
class JellyseerrConnection extends _$JellyseerrConnection {
  @override
  Future<JellyseerrConfig?> build() async {
    final access = ref.watch(directHomeAccessProvider);
    final result = await ref.watch(jellyseerrCredentialsStoreProvider).read();
    access.check();
    return result;
  }

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
  final connection = ref.watch(jellyseerrConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final health = ref
      .watch(healthMonitorProvider)
      .bind(
        IntegrationId.jellyseerr,
        configured: config != null,
        configurationIdentity: config,
      );
  ref.onDispose(health.close);
  if (config == null) return null;
  final client = JellyseerrClient(config: config, healthSession: health);
  ref.onDispose(client.dispose);
  return client;
}

@Riverpod(retry: noMediaReadRetry)
Future<List<JellyseerrRequestItem>> jellyseerrMyRequests(Ref ref) async {
  final client = ref.watch(jellyseerrClientProvider);
  if (client == null) return [];
  return client.myRequests();
}
