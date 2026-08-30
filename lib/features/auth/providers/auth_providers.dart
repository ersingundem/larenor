import 'package:riverpod_annotation/riverpod_annotation.dart';

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
  Future<HaConnectionConfig?> build() {
    return ref.watch(credentialsStoreProvider).read();
  }

  Future<void> signIn(HaConnectionConfig config) async {
    await ref.read(credentialsStoreProvider).save(config);
    state = AsyncData(config);
  }

  Future<void> signOut() async {
    await ref.read(credentialsStoreProvider).clear();
    state = const AsyncData(null);
  }
}
