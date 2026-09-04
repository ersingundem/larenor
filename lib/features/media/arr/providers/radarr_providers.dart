import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../health/data/integration_health.dart';
import '../../../health/providers/health_providers.dart';

import '../data/arr_client.dart';
import '../data/arr_config.dart';
import '../data/arr_credentials_store.dart';
import '../data/models/arr_calendar_item.dart';
import '../data/models/arr_queue_item.dart';

part 'radarr_providers.g.dart';

@riverpod
ArrCredentialsStore radarrCredentialsStore(Ref ref) =>
    ArrCredentialsStore(servicePrefix: 'radarr');

@riverpod
class RadarrConnection extends _$RadarrConnection {
  @override
  Future<ArrConfig?> build() =>
      ref.watch(radarrCredentialsStoreProvider).read();

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    final config = ArrConfig(baseUrl: baseUrl, apiKey: apiKey);
    await _client(config).checkConnection();
    await ref
        .read(radarrCredentialsStoreProvider)
        .save(baseUrl: baseUrl, apiKey: apiKey);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(radarrCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }

  ArrClient _client(ArrConfig config) =>
      ArrClient(config: config, resourcePath: 'movie', idFieldName: 'tmdbId');
}

@riverpod
ArrClient? radarrClient(Ref ref) {
  final config = ref.watch(radarrConnectionProvider).value;
  final health = ref
      .watch(healthMonitorProvider)
      .bind(IntegrationId.radarr, configured: config != null);
  ref.onDispose(health.close);
  if (config == null) return null;
  final client = ArrClient(
    config: config,
    healthSession: health,
    resourcePath: 'movie',
    idFieldName: 'tmdbId',
  );
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<ArrCalendarItem>> radarrCalendar(Ref ref) async {
  final client = ref.watch(radarrClientProvider);
  if (client == null) return [];
  return client.getCalendar();
}

@riverpod
Future<List<ArrQueueItem>> radarrQueue(Ref ref) async {
  final client = ref.watch(radarrClientProvider);
  if (client == null) return [];
  final items = await client.getQueue();
  if (ref.mounted) client.healthSession?.readSucceeded();
  return items;
}
