import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/direct_home_access.dart';

import '../../data/media_api_exception.dart';
import '../data/arr_client.dart';
import '../data/arr_config.dart';
import '../data/arr_credentials_store.dart';
import '../data/models/arr_calendar_item.dart';
import '../data/models/arr_queue_item.dart';

part 'lidarr_providers.g.dart';

@riverpod
ArrCredentialsStore lidarrCredentialsStore(Ref ref) =>
    ArrCredentialsStore(servicePrefix: 'lidarr', access: ref.watch(directHomeAccessProvider));

@riverpod
class LidarrConnection extends _$LidarrConnection {
  @override
  Future<ArrConfig?> build() async {
    final access = ref.watch(directHomeAccessProvider);
    access.check();
    final result = await ref.watch(lidarrCredentialsStoreProvider).read();
    access.check();
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    return result;
  }

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    final config = ArrConfig(baseUrl: baseUrl, apiKey: apiKey);
    await _client(config).checkConnection();
    await ref
        .read(lidarrCredentialsStoreProvider)
        .save(baseUrl: baseUrl, apiKey: apiKey);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(lidarrCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }

  ArrClient _client(ArrConfig config) => ArrClient(
    config: config,
    resourcePath: 'artist',
    idFieldName: 'foreignArtistId',
    apiVersion: 'v1',
  );
}

@riverpod
ArrClient? lidarrClient(Ref ref) {
  final connection = ref.watch(lidarrConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  if (config == null) return null;
  final client = ArrClient(
    config: config,
    resourcePath: 'artist',
    idFieldName: 'foreignArtistId',
    apiVersion: 'v1',
  );
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<ArrCalendarItem>> lidarrCalendar(Ref ref) async {
  final client = ref.watch(lidarrClientProvider);
  if (client == null) return [];
  return client.getCalendar();
}

@Riverpod(retry: noMediaReadRetry)
Future<List<ArrQueueItem>> lidarrQueue(Ref ref) async {
  final client = ref.watch(lidarrClientProvider);
  if (client == null) return [];
  return client.getQueue();
}
