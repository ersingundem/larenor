import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The pinned plugin's actual method-channel seam, rather than a store stub.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';

import '../../../core/direct_home_boundary_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late fixture.SecurePlatform platform;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    platform = fixture.SecurePlatform();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          platform.handle,
        );
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  test('explicit transfer reads the actual HA pair without mutating it', () async {
    // Dynamic only for the first missing-API runtime RED checkpoint. The final
    // tests call the typed production method after that API exists.
    final dynamic store = CredentialsStore();
    final value = await store.readForTransfer(isCurrent: () => true)
        as HaConnectionConfig?;
    expect(value?.baseUrl, 'https://synthetic.invalid');
    expect(value?.token, 'synthetic-secret');
    expect(platform.calls, [
      ('read', CredentialsStore.pendingMutationKey),
      ('read', 'ha_base_url'),
      ('read', 'ha_token'),
    ]);
    expect(platform.values['ha_token'], 'synthetic-secret');
  });
}
