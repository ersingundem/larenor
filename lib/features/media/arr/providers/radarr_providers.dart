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
    final result = await ref.watch(radarrCredentialsStoreProvider).read();
    _check(operation);
    return result;
  }

  Future<void> signIn({required String baseUrl, required String apiKey}) async {
    _check();
    if (_checkingClient != null) throw const DirectHomeAccessException('busy');
    final operation = ++_operation;
    final store = ref.read(radarrCredentialsStoreProvider);
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
    final store = ref.read(radarrCredentialsStoreProvider);
    _closeCheck();
    await store.clear();
    _check(operation);
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
