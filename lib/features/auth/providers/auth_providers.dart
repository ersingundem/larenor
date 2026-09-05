import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/direct_home_access.dart';

import '../../health/data/integration_health.dart';
import '../../health/providers/health_providers.dart';

import '../data/credentials_store.dart';
import '../data/ha_connection_config.dart';

part 'auth_providers.g.dart';

@riverpod
CredentialsStore credentialsStore(Ref ref) =>
    CredentialsStore(access: ref.watch(directHomeAccessProvider));

/// The active Home Assistant connection, if the user has signed in.
/// `null` means "not connected" — the app should show the connect screen.
@riverpod
class ConnectionConfig extends _$ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async {
    final access = ref.watch(directHomeAccessProvider);
    access.check();
    final store = ref.watch(credentialsStoreProvider);
    final health = ref.read(healthMonitorProvider);
    final config = await store.read();
    access.check();
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    if (ref.mounted) health.synchronizeConfiguration(IntegrationId.ha, config);
    return config;
  }

  Future<void> signIn(HaConnectionConfig config) async {
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    final access = ref.read(directHomeAccessProvider);
    access.check();
    await ref.read(credentialsStoreProvider).save(config);
    access.check();
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    ref
        .read(healthMonitorProvider)
        .synchronizeConfiguration(IntegrationId.ha, config);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    final access = ref.read(directHomeAccessProvider);
    access.check();
    await ref.read(credentialsStoreProvider).clear();
    access.check();
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    ref
        .read(healthMonitorProvider)
        .synchronizeConfiguration(IntegrationId.ha, null);
    state = const AsyncData(null);
  }
}
