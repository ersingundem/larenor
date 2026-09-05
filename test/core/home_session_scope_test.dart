import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_session_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/client_updates/data/client_update_api.dart';
import 'package:larenor/features/client_updates/providers/client_update_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/navigation/presentation/app_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Source implements HomeSourcePersistence {
  _Source(this.value);
  HomeSource value;
  int reads = 0;
  @override
  Future<HomeSource> read() async { reads++; return value; }
  @override
  Future<void> write(HomeSource source) async { value = source; }
}

class _Connection extends ConnectionConfig {
  int reads = 0;
  @override
  Future<HaConnectionConfig?> build() async { reads++; return null; }
}

void main() {
  testWidgets('saved Core source never loads legacy HA configuration on startup', (tester) async {
    SharedPreferences.setMockInitialValues({'enabled_services_migrated': true});
    FlutterSecureStorage.setMockInitialValues({});
    final source = _Source(HomeSource.verifiedCore);
    final connection = _Connection();
    await tester.pumpWidget(ProviderScope(
      overrides: [homeSourceStoreProvider.overrideWithValue(source)],
      child: HomeSessionScope(runtimeOverrides: [
        connectionConfigProvider.overrideWith(() => connection),
        clientUpdateApiProvider.overrideWithValue(AndroidClientUpdateApi(isAndroid: false)),
        haRestClientProvider.overrideWithValue(null),
        haWebSocketClientProvider.overrideWithValue(null),
      ]),
    ));
    for (var i = 0; i < 12; i++) { await tester.pump(const Duration(milliseconds: 50)); }
    expect(connection.reads, 0, reason: 'a saved Core choice must not mount local HA or its caches');
    expect(source.reads, 1);
    expect(find.byType(AppShell), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
