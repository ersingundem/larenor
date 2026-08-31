import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/arr_client.dart';
import '../data/arr_config.dart';
import '../data/arr_credentials_store.dart';
import '../data/models/arr_calendar_item.dart';
import '../data/models/arr_queue_item.dart';

part 'readarr_providers.g.dart';

@riverpod
ArrCredentialsStore readarrCredentialsStore(Ref ref) =>
    ArrCredentialsStore(servicePrefix: 'readarr');

@riverpod
class ReadarrConnection extends _$ReadarrConnection {
  @override
  Future<ArrConfig?> build() =>
      ref.watch(readarrCredentialsStoreProvider).read();

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    final config = ArrConfig(baseUrl: baseUrl, apiKey: apiKey);
    await _client(config).checkConnection();
    await ref
        .read(readarrCredentialsStoreProvider)
        .save(baseUrl: baseUrl, apiKey: apiKey);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(readarrCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }

  ArrClient _client(ArrConfig config) => ArrClient(
    config: config,
    resourcePath: 'author',
    idFieldName: 'foreignAuthorId',
    apiVersion: 'v1',
  );
}

@riverpod
ArrClient? readarrClient(Ref ref) {
  final config = ref.watch(readarrConnectionProvider).value;
  if (config == null) return null;
  final client = ArrClient(
    config: config,
    resourcePath: 'author',
    idFieldName: 'foreignAuthorId',
    apiVersion: 'v1',
  );
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<ArrCalendarItem>> readarrCalendar(Ref ref) async {
  final client = ref.watch(readarrClientProvider);
  if (client == null) return [];
  return client.getCalendar();
}

@riverpod
Future<List<ArrQueueItem>> readarrQueue(Ref ref) async {
  final client = ref.watch(readarrClientProvider);
  if (client == null) return [];
  return client.getQueue();
}
