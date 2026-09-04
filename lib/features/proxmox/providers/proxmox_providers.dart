import 'package:riverpod_annotation/riverpod_annotation.dart';

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

@riverpod
ProxmoxCredentialsStore proxmoxCredentialsStore(Ref ref) =>
    ProxmoxCredentialsStore();

@riverpod
class ProxmoxConnection extends _$ProxmoxConnection {
  @override
  Future<ProxmoxConfig?> build() =>
      ref.watch(proxmoxCredentialsStoreProvider).read();

  Future<void> signIn({
    required String host,
    required int port,
    required String username,
    required String realm,
    required String password,
    required bool allowSelfSigned,
  }) async {
    final config = ProxmoxConfig(
      host: host,
      port: port,
      username: username,
      realm: realm,
      password: password,
      allowSelfSigned: allowSelfSigned,
    );

    final client = ProxmoxClient(config: config);
    try {
      await client.login();
      await client.getNodes();
    } catch (_) {
      throw ProxmoxApiException(
        'Could not sign in — check host/port and credentials.',
      );
    } finally {
      client.dispose();
    }

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
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(proxmoxCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }
}

@riverpod
Future<ProxmoxClient?> proxmoxClient(Ref ref) async {
  final config = ref.watch(proxmoxConnectionProvider).value;
  if (config == null) return null;

  final client = ProxmoxClient(config: config);
  ref.onDispose(client.dispose);
  await client.login();
  return client;
}

@riverpod
Future<List<ProxmoxNode>> proxmoxNodes(Ref ref) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (client == null) return [];
  return client.getNodes();
}

@riverpod
Future<List<ProxmoxGuest>> proxmoxGuests(Ref ref, String node) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (client == null) return [];
  return client.getGuests(node);
}

@riverpod
Future<List<ProxmoxTask>> proxmoxTasks(Ref ref, String node) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (client == null) return [];
  return client.getTasks(node);
}

@riverpod
Future<List<ProxmoxStorage>> proxmoxStorages(Ref ref, String node) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (client == null) return [];
  return client.getStorages(node);
}

@riverpod
Future<Map<String, dynamic>> proxmoxGuestConfig(
  Ref ref,
  String node,
  ProxmoxGuestType type,
  int vmid,
) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (client == null) return {};
  return client.getGuestConfig(node, type, vmid);
}

@riverpod
Future<List<ProxmoxBackup>> proxmoxBackups(
  Ref ref,
  String node,
  String storage,
) async {
  final client = await ref.watch(proxmoxClientProvider.future);
  if (client == null) return [];
  return client.getBackups(node, storage);
}
