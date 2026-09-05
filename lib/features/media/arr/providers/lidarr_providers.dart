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
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  int _operation = 0;
  ArrClient? _checkingClient;

  void _check([int? operation]) {
    if (!ref.mounted || operation != null && operation != _operation) {
      throw const DirectHomeAccessException('unavailable');
    }
    _access.check();
  }
  void _closeCheck() {
    _checkingClient?.dispose();
    _checkingClient = null;
  }

  @override
  Future<ArrConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    final operation = ++_operation;
    ref.onDispose(() { _operation++; _closeCheck(); });
    _check(operation);
    final result = await ref.watch(lidarrCredentialsStoreProvider).read();
    _check(operation);
    return result;
  }

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    _check();
    if (_checkingClient != null) throw const DirectHomeAccessException('busy');
    final operation = ++_operation;
    final store = ref.read(lidarrCredentialsStoreProvider);
    final config = ArrConfig(baseUrl: baseUrl, apiKey: apiKey);
    final client = _client(config);
    _checkingClient = client;
    try {
      await client.checkConnection();
      _check(operation);
      await store.save(baseUrl: baseUrl, apiKey: apiKey);
      _check(operation);
      state = AsyncData(config);
    } catch (_) {
      _check(operation);
      rethrow;
    } finally {
      if (identical(_checkingClient, client)) _closeCheck();
    }
  }

  Future<void> signOut() async {
    _check();
    final operation = ++_operation;
    final store = ref.read(lidarrCredentialsStoreProvider);
    _closeCheck();
    await store.clear();
    _check(operation);
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
