import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

import '../../../core/configuration_writes.dart';
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
    ProxmoxCredentialsStore();

@riverpod
class ProxmoxConnection extends _$ProxmoxConnection {
  int _generation = 0;
  ProxmoxClient? _verificationClient;
  @override
  Future<ProxmoxConfig?> build() {
    ref.onDispose(() {
      _generation++;
      _verificationClient?.dispose();
    });
    return ref.watch(proxmoxCredentialsStoreProvider).read();
  }

  Future<void> signIn({
    required String host,
    required int port,
    required String username,
    required String realm,
    required String password,
    required bool allowSelfSigned,
  }) async {
    final previous = state.value;
    final generation = ++_generation;
    _verificationClient?.dispose();
    state = const AsyncLoading();
    ProxmoxClient? client;
    bool current() => ref.mounted && generation == _generation;
    try {
      final config = ProxmoxConfig(
        host: host,
        port: port,
        username: username,
        realm: realm,
        password: password,
        allowSelfSigned: allowSelfSigned,
      );
      client = ref.read(proxmoxClientFactoryProvider)(config, null);
      _verificationClient = client;
      await client.login();
      if (!current()) return;
      await client.getNodes();
      await ConfigurationWrites.run(() async {
        if (!current()) return;
        await ref
            .read(proxmoxCredentialsStoreProvider)
            .save(
              host: host,
              port: port,
              username: username,
              realm: realm,
              password: password,
              allowSelfSigned: allowSelfSigned,
            );
        if (current()) state = AsyncData(config);
      });
    } catch (_) {
      if (current()) state = AsyncData(previous);
      throw ProxmoxApiException(
        'Could not sign in — check host/port and credentials.',
      );
    } finally {
      client?.dispose();
      if (identical(client, _verificationClient)) _verificationClient = null;
    }
  }

  Future<void> signOut() async {
    final generation = ++_generation;
    _verificationClient?.dispose();
    state = const AsyncLoading();
    await ConfigurationWrites.run(() async {
      if (!ref.mounted || generation != _generation) return;
      await ref.read(proxmoxCredentialsStoreProvider).clear();
      if (ref.mounted && generation == _generation) {
        state = const AsyncData(null);
      }
    });
  }
}

@Riverpod(retry: _noRetry)
Future<ProxmoxClient?> proxmoxClient(Ref ref) async {
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
