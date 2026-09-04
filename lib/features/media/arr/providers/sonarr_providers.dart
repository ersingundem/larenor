import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../health/data/integration_health.dart';
import '../../../health/providers/health_providers.dart';

import '../data/arr_client.dart';
import '../data/arr_config.dart';
import '../data/arr_credentials_store.dart';
import '../data/models/arr_calendar_item.dart';
import '../data/models/arr_queue_item.dart';

part 'sonarr_providers.g.dart';

@riverpod
ArrCredentialsStore sonarrCredentialsStore(Ref ref) =>
    ArrCredentialsStore(servicePrefix: 'sonarr');

@riverpod
class SonarrConnection extends _$SonarrConnection {
  @override
  Future<ArrConfig?> build() =>
      ref.watch(sonarrCredentialsStoreProvider).read();

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    final config = ArrConfig(baseUrl: baseUrl, apiKey: apiKey);
    await _client(config).checkConnection();
    await ref
        .read(sonarrCredentialsStoreProvider)
        .save(baseUrl: baseUrl, apiKey: apiKey);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(sonarrCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }

  ArrClient _client(ArrConfig config) =>
      ArrClient(config: config, resourcePath: 'series', idFieldName: 'tvdbId');
}

@riverpod
ArrClient? sonarrClient(Ref ref) {
  final config = ref.watch(sonarrConnectionProvider).value;
  final health = ref
      .watch(healthMonitorProvider)
      .bind(IntegrationId.sonarr, configured: config != null);
  ref.onDispose(health.close);
  if (config == null) return null;
  final client = ArrClient(
    config: config,
    healthSession: health,
    resourcePath: 'series',
    idFieldName: 'tvdbId',
  );
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<ArrCalendarItem>> sonarrCalendar(Ref ref) async {
  final client = ref.watch(sonarrClientProvider);
  if (client == null) return [];
  return client.getCalendar();
}

@riverpod
Future<List<ArrQueueItem>> sonarrQueue(Ref ref) async {
  final client = ref.watch(sonarrClientProvider);
  if (client == null) return [];
  final items = await client.getQueue();
  if (ref.mounted) client.healthSession?.readSucceeded();
  return items;
}
