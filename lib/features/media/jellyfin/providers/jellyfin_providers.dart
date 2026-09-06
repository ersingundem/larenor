import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:http/http.dart' as http;

import '../../../../core/direct_home_access.dart';

import '../../../health/data/integration_health.dart';
import '../../../health/providers/health_providers.dart';

import '../data/jellyfin_client.dart';
import '../data/jellyfin_config.dart';
import '../data/jellyfin_credentials_store.dart';
import '../data/models/jellyfin_item.dart';

part 'jellyfin_providers.g.dart';

@riverpod
JellyfinCredentialsStore jellyfinCredentialsStore(Ref ref) =>
    JellyfinCredentialsStore(access: ref.watch(directHomeAccessProvider));

@riverpod
class JellyfinConnection extends _$JellyfinConnection {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  int _operation = 0;
  bool _signingIn = false;
  http.Client? _checkingClient;

  void _check([int? operation]) {
    if (!ref.mounted || operation != null && operation != _operation) {
      throw const DirectHomeAccessException('unavailable');
    }
    _access.check();
  }

  void _closeCheck() {
    _checkingClient?.close();
    _checkingClient = null;
  }

  @override
  Future<JellyfinConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    final operation = ++_operation;
    ref.onDispose(() { _operation++; _signingIn = false; _closeCheck(); });
    _check(operation);
    final result = await ref.watch(jellyfinCredentialsStoreProvider).read();
    _check(operation);
    return result;
  }

  Future<void> signIn({required String baseUrl, required String username,
    required String password, bool Function()? isCurrent}) async {
    void checkAction() {
      try { if (isCurrent == null || isCurrent()) return; } catch (_) { /* Static denial. */ }
      throw const DirectHomeAccessException('unavailable');
    }
    _check(); checkAction();
    if (_signingIn) throw const DirectHomeAccessException('busy');
    _signingIn = true;
    final operation = ++_operation;
    final store = ref.read(jellyfinCredentialsStoreProvider);
    bool current() { _check(operation); checkAction(); return true; }
    http.Client? client;
    try {
      final device = await store.deviceId(isCurrent: current);
      current();
      client = http.Client();
      _checkingClient = client;
      final config = await JellyfinClient.login(baseUrl: baseUrl, username: username,
        password: password, deviceId: device, httpClient: client);
      current();
      await store.save(baseUrl: config.baseUrl, userId: config.userId,
        accessToken: config.accessToken, isCurrent: current);
      current();
      state = AsyncData(config);
    } catch (_) {
      _check(operation);
      rethrow;
    } finally {
      if (identical(_checkingClient, client)) _closeCheck();
      if (_operation == operation) _signingIn = false;
    }
  }

  Future<void> signOut() async {
    _check();
    final operation = ++_operation;
    final store = ref.read(jellyfinCredentialsStoreProvider);
    _signingIn = false;
    _closeCheck();
    await store.clear(isCurrent: () { _check(operation); return true; });
    _check(operation);
    state = const AsyncData(null);
  }
}

@riverpod
JellyfinClient? jellyfinClient(Ref ref) {
  final access = ref.watch(directHomeAccessProvider);
  if (!access.isCurrent) return null;
  final connection = ref.watch(jellyfinConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final health = ref
      .watch(healthMonitorProvider)
      .bind(
        IntegrationId.jellyfin,
        configured: config != null,
        configurationIdentity: config,
      );
  ref.onDispose(health.close);
  if (config == null) return null;
  final client = JellyfinClient(config: config, healthSession: health);
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Future<List<JellyfinItem>> jellyfinResumeItems(Ref ref) async {
  final client = ref.watch(jellyfinClientProvider);
  if (client == null) return [];
  return client.getResumeItems();
}

@riverpod
Future<List<JellyfinItem>> jellyfinLatestItems(Ref ref) async {
  final client = ref.watch(jellyfinClientProvider);
  if (client == null) return [];
  return client.getLatestItems();
}

@riverpod
Future<List<JellyfinItem>> jellyfinLibraries(Ref ref) async {
  final client = ref.watch(jellyfinClientProvider);
  if (client == null) return [];
  return client.getLibraries();
}

@riverpod
Future<List<JellyfinItem>> jellyfinLibraryItems(
  Ref ref,
  String parentId,
) async {
  final client = ref.watch(jellyfinClientProvider);
  if (client == null) return [];
  return client.getItemsInLibrary(parentId);
}
