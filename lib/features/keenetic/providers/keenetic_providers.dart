import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/keenetic_client.dart';
import '../data/keenetic_config.dart';
import '../data/keenetic_credentials_store.dart';
import '../data/models/keenetic_access_point.dart';
import '../data/models/keenetic_device.dart';
import '../data/models/keenetic_port_forward.dart';

part 'keenetic_providers.g.dart';

@riverpod
KeeneticCredentialsStore keeneticCredentialsStore(Ref ref) =>
    KeeneticCredentialsStore();

@riverpod
class KeeneticConnection extends _$KeeneticConnection {
  @override
  Future<KeeneticConfig?> build() =>
      ref.watch(keeneticCredentialsStoreProvider).read();

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final config = KeeneticConfig(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
    final client = KeeneticClient(config: config);
    try {
      await client.login();
      await client.checkConnection();
    } finally {
      client.dispose();
    }

    await ref
        .read(keeneticCredentialsStoreProvider)
        .save(baseUrl: baseUrl, username: username, password: password);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(keeneticCredentialsStoreProvider).clear();
    state = const AsyncData(null);
  }
}

@riverpod
Future<KeeneticClient?> keeneticClient(Ref ref) async {
  final config = ref.watch(keeneticConnectionProvider).value;
  if (config == null) return null;
  final client = KeeneticClient(config: config);
  await client.login();
  return client;
}

@riverpod
Future<List<KeeneticDevice>> keeneticDevices(Ref ref) async {
  final client = await ref.watch(keeneticClientProvider.future);
  if (client == null) return [];
  return client.getConnectedDevices();
}

@riverpod
Future<List<KeeneticAccessPoint>> keeneticAccessPoints(Ref ref) async {
  final client = await ref.watch(keeneticClientProvider.future);
  if (client == null) return [];
  return client.getAccessPoints();
}

@riverpod
Future<List<KeeneticPortForward>> keeneticPortForwarding(Ref ref) async {
  final client = await ref.watch(keeneticClientProvider.future);
  if (client == null) return [];
  return client.getPortForwardingRules();
}
