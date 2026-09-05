import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/direct_home_access.dart';

import '../../../health/data/integration_health.dart';
import '../../../health/providers/health_providers.dart';

import '../../data/media_api_exception.dart';
import '../data/arr_client.dart';
import '../data/arr_config.dart';
import '../data/arr_credentials_store.dart';
import '../data/models/arr_calendar_item.dart';
import '../data/models/arr_queue_item.dart';

part 'radarr_providers.g.dart';

@riverpod
ArrCredentialsStore radarrCredentialsStore(Ref ref) =>
    ArrCredentialsStore(servicePrefix: 'radarr', access: ref.watch(directHomeAccessProvider));

@riverpod
class RadarrConnection extends _$RadarrConnection {
  @override
  Future<ArrConfig?> build() async {
    final access = ref.watch(directHomeAccessProvider);
    access.check();
    final result = await ref.watch(radarrCredentialsStoreProvider).read();
    access.check();
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    return result;
  }

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
  final connection = ref.watch(radarrConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final health = ref
      .watch(healthMonitorProvider)
      .bind(
        IntegrationId.radarr,
        configured: config != null,
        configurationIdentity: config,
      );
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

@Riverpod(retry: noMediaReadRetry)
Future<List<ArrQueueItem>> radarrQueue(Ref ref) async {
  final client = ref.watch(radarrClientProvider);
  if (client == null) return [];
  final items = await client.getQueue();
  if (ref.mounted) client.healthSession?.readSucceeded();
  return items;
}
