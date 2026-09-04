import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../health/data/integration_health.dart';
import '../../health/providers/health_providers.dart';

import '../data/credentials_store.dart';
import '../data/ha_connection_config.dart';

part 'auth_providers.g.dart';

@riverpod
CredentialsStore credentialsStore(Ref ref) => CredentialsStore();

/// The active Home Assistant connection, if the user has signed in.
/// `null` means "not connected" — the app should show the connect screen.
@riverpod
class ConnectionConfig extends _$ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async {
    final store = ref.watch(credentialsStoreProvider);
    final health = ref.read(healthMonitorProvider);
    final config = await store.read();
    if (ref.mounted) health.synchronizeConfiguration(IntegrationId.ha, config);
    return config;
  }

  Future<void> signIn(HaConnectionConfig config) async {
    await ref.read(credentialsStoreProvider).save(config);
    ref
        .read(healthMonitorProvider)
        .synchronizeConfiguration(IntegrationId.ha, config);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(credentialsStoreProvider).clear();
    ref
        .read(healthMonitorProvider)
        .synchronizeConfiguration(IntegrationId.ha, null);
    state = const AsyncData(null);
  }
}
