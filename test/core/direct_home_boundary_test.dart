import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// The app's pinned secure-storage plugin owns this public platform seam.
// Restore its channel implementation after testExecutable's memory default.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class SourceStore implements HomeSourcePersistence {
  SourceStore(this.value);
  HomeSource value;
  @override
  Future<HomeSource> read() async => value;
  @override
  Future<void> write(HomeSource source) async => value = source;
}

class SessionStore implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

class PreferencePlatform extends InMemorySharedPreferencesStore {
  PreferencePlatform() : super.withData({});
  final writes = <String>[];
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    return super.setValue(type, key, value);
  }
}

class SecurePlatform {
  final values = <String, String>{
    'ha_base_url': 'https://synthetic.invalid',
    'ha_token': 'synthetic-secret',
    'jellyfin_base_url': 'https://synthetic.invalid',
    'jellyfin_user_id': 'synthetic-user',
    'jellyfin_access_token': 'synthetic-secret',
  };
  final calls = <(String, String?)>[];
  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments as Map;
    final key = args['key'] as String?;
    calls.add((call.method, key));
    switch (call.method) {
      case 'read':
        return values[key];
      case 'write':
        values[key!] = args['value'] as String;
        return null;
      case 'delete':
        values.remove(key);
        return null;
      case 'readAll':
        return Map<String, String>.of(values);
      case 'deleteAll':
        values.clear();
        return null;
      case 'containsKey':
        return values.containsKey(key);
      default:
        throw StateError('Unexpected secure storage method');
    }
  }
}

Future<(ProviderContainer, HomeSessionController)> containerFor(
  HomeSource source,
) async {
  final account = ServerAccountController(store: SessionStore());
  final home = HomeSessionController(
    store: SourceStore(source),
    account: account,
  );
  await home.initialize();
  home.runtimeMounted(home.runtimeIdentity);
  final container = ProviderContainer(
    overrides: [homeSessionControllerProvider.overrideWithValue(home)],
    retry: (_, _) => null,
  );
  addTearDown(() {
    container.dispose();
    home.dispose();
    account.dispose();
  });
  return (container, home);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecurePlatform secure;
  late PreferencePlatform preferences;
  late FlutterSecureStoragePlatform previousSecure;
  setUp(() {
    secure = SecurePlatform();
    previousSecure = FlutterSecureStoragePlatform.instance;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          secure.handle,
        );
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    SharedPreferences.resetStatic();
    preferences = PreferencePlatform();
    SharedPreferencesStorePlatform.instance = preferences;
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previousSecure;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  test('Core direct HA provider rejects before reading credentials', () async {
    final (container, _) = await containerFor(HomeSource.verifiedCore);
    final sub = container.listen(connectionConfigProvider, (_, _) {});
    addTearDown(sub.close);
    await expectLater(
      container.read(connectionConfigProvider.future),
      throwsA(isA<Exception>()),
    );
    expect(secure.calls, isEmpty);
  });

  test(
    'Core store handle cannot bypass source ownership for read save clear',
    () async {
      final (container, _) = await containerFor(HomeSource.verifiedCore);
      final sub = container.listen(credentialsStoreProvider, (_, _) {});
      addTearDown(sub.close);
      final store = sub.read();
      for (final operation in <Future<void> Function()>[
        () async {
          await store.read();
        },
        () => store.save(
          const HaConnectionConfig(
            baseUrl: 'https://synthetic.invalid',
            token: 'replacement',
          ),
        ),
        store.clear,
      ]) {
        await expectLater(
          Future<void>.sync(operation),
          throwsA(isA<Exception>()),
        );
      }
      expect(secure.calls, isEmpty);
    },
  );

  test(
    'Core enabled services does not scan secrets or mark migration',
    () async {
      final (container, _) = await containerFor(HomeSource.verifiedCore);
      final sub = container.listen(enabledServicesProvider, (_, _) {});
      addTearDown(sub.close);
      await expectLater(
        container.read(enabledServicesProvider.future),
        throwsA(isA<Exception>()),
      );
      expect(secure.calls, isEmpty);
      expect(preferences.writes, isEmpty);
    },
  );

  test(
    'Core enabled store cannot read or mutate the Direct preference',
    () async {
      final (container, _) = await containerFor(HomeSource.verifiedCore);
      final sub = container.listen(enabledServicesStoreProvider, (_, _) {});
      addTearDown(sub.close);
      final store = sub.read();
      await expectLater(store.read(), throwsA(isA<Exception>()));
      await expectLater(
        store.save({AppService.jellyfin}, markMigrated: true),
        throwsA(isA<Exception>()),
      );
      expect(preferences.writes, isEmpty);
    },
  );

  test('Direct background ownership survives inactive interaction', () async {
    final (container, home) = await containerFor(HomeSource.directLocal);
    home.interaction.setActive(false);
    final sub = container.listen(connectionConfigProvider, (_, _) {});
    addTearDown(sub.close);
    final config = await container.read(connectionConfigProvider.future);
    expect(config?.token, 'synthetic-secret');
    expect(secure.calls.where((call) => call.$1 == 'read').length, 2);
  });
}
