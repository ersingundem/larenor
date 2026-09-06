import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

import '../../../core/direct_home_access.dart';
import '../../health/data/health_monitor.dart';
import '../../health/data/integration_health.dart';
import '../../health/providers/health_providers.dart';

import '../data/proxmox_api_exception.dart';
import '../data/proxmox_client.dart';
import '../data/proxmox_config.dart';
import '../data/proxmox_credentials_store.dart';
import '../data/models/proxmox_backup.dart';
import '../data/models/proxmox_guest.dart';
import '../data/models/proxmox_node.dart';
import '../data/models/proxmox_storage.dart';
import '../data/models/proxmox_task.dart';

part 'proxmox_providers.g.dart';

typedef ProxmoxClientFactory = ProxmoxClient Function(
  ProxmoxConfig config,
  HealthSession? health,
);
final proxmoxClientFactoryProvider = Provider<ProxmoxClientFactory>(
  (ref) =>
      (config, health) => ProxmoxClient(config: config, healthSession: health),
);
final proxmoxHealthSessionProvider = Provider.autoDispose<HealthSession>((ref) {
  final connection = ref.watch(proxmoxConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final session = ref
      .watch(healthMonitorProvider)
      .bind(
        IntegrationId.proxmox,
        configured: config != null,
        configurationIdentity: config,
      );
  ref.onDispose(session.close);
  return session;
});

@riverpod
ProxmoxCredentialsStore proxmoxCredentialsStore(Ref ref) =>
    ProxmoxCredentialsStore(access: ref.watch(directHomeAccessProvider));

@riverpod
class ProxmoxConnection extends _$ProxmoxConnection {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  int _generation = 0;
  ProxmoxClient? _verificationClient;
  bool Function()? _verificationOwner;
  int? _verificationGeneration;

  void _check([int? generation]) {
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    _access.check();
    if (generation != null && generation != _generation) {
      throw const DirectHomeAccessException('unavailable');
    }
  }

  void _closeCheck() {
    _verificationClient?.dispose();
    _verificationClient = null;
    _verificationOwner = null;
    _verificationGeneration = null;
  }

  /// Only the owner of this verification may close its transport. Normal
  /// readers and a newer sign-in are independent; no storage or retry occurs.
  void cancelSignIn(bool Function() owner) {
    if (identical(owner, _verificationOwner) &&
        _verificationGeneration == _generation) {
      _verificationClient?.dispose();
    }
  }

  @override
  Future<ProxmoxConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    final generation = ++_generation;
    ref.onDispose(() {
      _generation++;
      _closeCheck();
    });
    _check(generation);
    final value = await ref.watch(proxmoxCredentialsStoreProvider).read();
    _check(generation);
    return value;
  }

  Future<void> signIn({
    required String host,
    required int port,
    required String username,
    required String realm,
    required String password,
    required bool allowSelfSigned,
    bool Function()? isCurrent,
  }) async {
    void checkAction() {
      try {
        if (isCurrent == null || isCurrent()) return;
      } catch (_) {}
      throw const DirectHomeAccessException('unavailable');
    }

    _check();
    checkAction();
    final previous = state;
    final generation = ++_generation;
    final store = ref.read(proxmoxCredentialsStoreProvider);
    final factory = ref.read(proxmoxClientFactoryProvider);
    _closeCheck();
    // Empty/pending setup owns its form while verifying. An existing reader
    // still retires before replacement, so retained config cannot authenticate.
    if (!previous.isLoading && !previous.hasError && previous.value != null) {
      state = const AsyncLoading();
    }
    bool current() =>
        ref.mounted && _access.isCurrent && generation == _generation;
    bool actionCurrent() {
      if (!current()) return false;
      try {
        return isCurrent == null || isCurrent();
      } catch (_) {
        return false;
      }
    }

    ProxmoxClient? client;
    try {
      final config = ProxmoxConfig(
        host: host,
        port: port,
        username: username,
        realm: realm,
        password: password,
        allowSelfSigned: allowSelfSigned,
      );
      client = factory(config, null);
      _verificationClient = client;
      _verificationOwner = isCurrent;
      _verificationGeneration = generation;
      await client.login();
      _check(generation);
      checkAction();
      await client.getNodes();
      _check(generation);
      checkAction();
      await store.save(
        host: host,
        port: port,
        username: username,
        realm: realm,
        password: password,
        allowSelfSigned: allowSelfSigned,
        isCurrent: actionCurrent,
      );
      _check(generation);
      checkAction();
      state = AsyncData(config);
    } catch (error) {
      _check(generation);
      try {
        checkAction();
      } on DirectHomeAccessException catch (expired) {
        state = AsyncError(expired, StackTrace.empty);
        rethrow;
      }
      if (error is DirectHomeAccessException) {
        state = AsyncError(error, StackTrace.empty);
        rethrow;
      }
      if (current()) {
        state = previous.isLoading
            ? AsyncError(
                const DirectHomeAccessException('unavailable'),
                StackTrace.empty,
              )
            : previous;
      }
      throw ProxmoxApiException(
        'Could not sign in — check host/port and credentials.',
      );
    } finally {
      client?.dispose();
      if (identical(client, _verificationClient)) {
        _verificationClient = null;
        _verificationOwner = null;
        _verificationGeneration = null;
      }
    }
  }

  Future<void> signOut({bool Function()? isCurrent}) async {
    bool actionCurrent(int generation) {
      if (!ref.mounted || !_access.isCurrent || generation != _generation)
        return false;
      try {
        return isCurrent == null || isCurrent();
      } catch (_) {
        return false;
      }
    }

    _check();
    if (!actionCurrent(_generation))
      throw const DirectHomeAccessException('unavailable');
    final generation = ++_generation;
    final store = ref.read(proxmoxCredentialsStoreProvider);
    _closeCheck();
    state = const AsyncLoading();
    try {
      await store.clear(isCurrent: () => actionCurrent(generation));
      _check(generation);
      if (!actionCurrent(generation))
        throw const DirectHomeAccessException('unavailable');
      state = const AsyncData(null);
    } catch (_) {
      _check(generation);
      state = AsyncError(
        const DirectHomeAccessException('write_unconfirmed'),
        StackTrace.empty,
      );
      rethrow;
    }
  }
}

@Riverpod(retry: _noRetry)
Future<ProxmoxClient?> proxmoxClient(Ref ref) async {
  final access = ref.watch(directHomeAccessProvider);
  access.check();
  final connection = ref.watch(proxmoxConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final health = ref.watch(proxmoxHealthSessionProvider);
  if (config == null) return null;
  final client = ref.watch(proxmoxClientFactoryProvider)(config, health);
  ref.onDispose(client.dispose);
  try {
    await client.login();
    access.check();
    if (!ref.mounted) {
      client.dispose();
      return null;
    }
    return client;
  } catch (_) {
    client.dispose();
    rethrow;
  }
}

@Riverpod(retry: _noRetry)
Future<List<ProxmoxNode>> proxmoxNodes(Ref ref) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.getNodes();
}

@Riverpod(retry: _noRetry)
Future<List<ProxmoxGuest>> proxmoxGuests(Ref ref, String node) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.getGuests(node);
}

@Riverpod(retry: _noRetry)
Future<List<ProxmoxTask>> proxmoxTasks(Ref ref, String node) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.getTasks(node);
}

@Riverpod(retry: _noRetry)
Future<List<ProxmoxStorage>> proxmoxStorages(Ref ref, String node) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.getStorages(node);
}

@Riverpod(retry: _noRetry)
Future<Map<String, dynamic>> proxmoxGuestConfig(
  Ref ref,
  String node,
  ProxmoxGuestType type,
  int vmid,
) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (!ref.mounted || client == null) return {};
  return client.getGuestConfig(node, type, vmid);
}

@Riverpod(retry: _noRetry)
Future<List<ProxmoxBackup>> proxmoxBackups(
  Ref ref,
  String node,
  String storage,
) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.getBackups(node, storage);
}

Duration? _noRetry(int retryCount, Object error) => null;
