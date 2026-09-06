import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/direct_home_access.dart';

import '../../data/media_api_exception.dart';
import '../data/arr_client.dart';
import '../data/arr_config.dart';
import '../data/arr_credentials_store.dart';
import '../data/models/arr_calendar_item.dart';
import '../data/models/arr_queue_item.dart';

part 'readarr_providers.g.dart';

@riverpod
ArrCredentialsStore readarrCredentialsStore(Ref ref) => ArrCredentialsStore(
  servicePrefix: 'readarr',
  access: ref.watch(directHomeAccessProvider),
);

@riverpod
class ReadarrConnection extends _$ReadarrConnection {
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
    ref.onDispose(() {
      _operation++;
      _closeCheck();
    });
    _check(operation);
    final result = await ref.watch(readarrCredentialsStoreProvider).read();
    _check(operation);
    return result;
  }

  Future<void> signIn({
    required String baseUrl,
    required String apiKey,
    bool Function()? isCurrent,
  }) async {
    void checkAction() {
      try {
        if (isCurrent == null || isCurrent()) return;
      } catch (_) {}
      throw const DirectHomeAccessException('unavailable');
    }

    checkAction();
    _check();
    if (_checkingClient != null) throw const DirectHomeAccessException('busy');
    final operation = ++_operation;
    final store = ref.read(readarrCredentialsStoreProvider);
    final config = ArrConfig(baseUrl: baseUrl, apiKey: apiKey);
    final client = _client(config);
    _checkingClient = client;
    try {
      await client.checkConnection();
      _check(operation);
      checkAction();
      await store.save(baseUrl: baseUrl, apiKey: apiKey, isCurrent: isCurrent);
      _check(operation);
      checkAction();
      state = AsyncData(config);
    } catch (error, stack) {
      _recordFailure(operation, error, stack);
      rethrow;
    } finally {
      if (identical(_checkingClient, client)) _closeCheck();
    }
  }

  Future<void> signOut() async {
    _check();
    final operation = ++_operation;
    final store = ref.read(readarrCredentialsStoreProvider);
    _closeCheck();
    try {
      await store.clear();
      _check(operation);
      state = const AsyncData(null);
    } catch (error, stack) {
      _recordFailure(operation, error, stack);
      rethrow;
    }
  }

  void _recordFailure(int operation, Object error, StackTrace stack) {
    // An old action must not publish a failure into a newer source or login.
    _check(operation);
    if (error is DirectHomeAccessException &&
        const {'write_unconfirmed', 'pending_mutation', 'storage_failed'}
            .contains(error.code)) {
      state = AsyncError(error, stack);
    }
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
  final connection = ref.watch(readarrConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
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

@Riverpod(retry: noMediaReadRetry)
Future<List<ArrQueueItem>> readarrQueue(Ref ref) async {
  final client = ref.watch(readarrClientProvider);
  if (client == null) return [];
  return client.getQueue();
}
