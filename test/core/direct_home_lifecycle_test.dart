import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Uses the pinned secure-storage plugin's public platform test seam.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/auth/data/credentials_store.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'direct_home_boundary_test.dart' as fixture;

const replacement = HaConnectionConfig(
  baseUrl: 'https://new.invalid',
  token: 'new-secret',
);

class Secure extends fixture.SecurePlatform {
  Future<void> Function(String, String?)? after;
  @override
  Future<Object?> handle(MethodCall call) async {
    final result = await super.handle(call);
    await after?.call(call.method, (call.arguments as Map)['key'] as String?);
    return result;
  }
}

class Preferences extends InMemorySharedPreferencesStore {
  Preferences([super.data = const {}]) : super.withData();
  final writes = <String>[];
  int reads = 0;
  Future<void> Function()? afterRead;
  Future<void> Function(String)? afterWrite;
  String? falseKey;
  String? throwKey;
  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    final result = await super.getAll();
    await afterRead?.call();
    return result;
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    if (key == throwKey) throw const FormatException('sentinel-private-prefs');
    if (key == falseKey) return false;
    final result = await super.setValue(type, key, value);
    await afterWrite?.call(key);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Secure secure;
  late Preferences prefs;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    secure = Secure();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          secure.handle,
        );
    SharedPreferences.resetStatic();
    prefs = Preferences();
    SharedPreferencesStorePlatform.instance = prefs;
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  test(
    'a captured store remains retired after Direct Core Direct round trip',
    () async {
      final (container, home) = await fixture.containerFor(
        HomeSource.directLocal,
      );
      final sub = container.listen(credentialsStoreProvider, (_, _) {});
      addTearDown(sub.close);
      final oldStore = sub.read();
      await home.choose(HomeSource.verifiedCore);
      await home.choose(HomeSource.directLocal);
      for (final action in [
        () async {
          await oldStore.read();
        },
        () => oldStore.save(replacement),
        oldStore.clear,
      ]) {
        await expectLater(
          Future<void>.sync(action),
          throwsA(isA<DirectHomeAccessException>()),
        );
      }
      expect(secure.calls, isEmpty);
      expect(
        (await container.read(credentialsStoreProvider).read())?.token,
        'synthetic-secret',
      );
    },
  );

  test(
    'store retained past provider disposal cannot perform storage work',
    () async {
      final container = ProviderContainer();
      final store = container.read(credentialsStoreProvider);
      container.dispose();
      for (final action in [
        () async {
          await store.read();
        },
        () => store.save(replacement),
        store.clear,
      ]) {
        await expectLater(
          Future<void>.sync(action),
          throwsA(isA<DirectHomeAccessException>()),
        );
      }
      expect(secure.calls, isEmpty);
    },
  );

  test('pending real provider read never consumes token or publishes after Core switch', () async {
    final (container, home) = await fixture.containerFor(
      HomeSource.directLocal,
    );
    final reached = Completer<void>(), release = Completer<void>();
    secure.after = (method, key) async {
      if (method == 'read' && key == 'ha_base_url') {
        reached.complete();
        await release.future;
      }
    };
    final states = <AsyncValue<HaConnectionConfig?>>[];
    final sub = container.listen(
      connectionConfigProvider,
      (_, next) => states.add(next),
    );
    addTearDown(sub.close);
    final waiting = expectLater(
      container.read(connectionConfigProvider.future),
      throwsA(isA<Exception>()),
    );
    await reached.future;
    await home.choose(HomeSource.verifiedCore);
    release.complete();
    await waiting;
    await Future<void>.delayed(Duration.zero);
    expect(secure.calls, [
      ('read', CredentialsStore.pendingMutationKey),
      ('read', 'ha_base_url'),
    ]);
    expect(states.where((s) => s.hasValue && s.value != null), isEmpty);
  });

  for (final signOut in [false, true]) {
    for (var stop = 0; stop < 4; stop++) {
      test(
        '${signOut ? 'signOut' : 'signIn'} stops after source changes at effect $stop',
        () async {
          final (container, home) = await fixture.containerFor(
            HomeSource.directLocal,
          );
          final states = <AsyncValue<HaConnectionConfig?>>[];
          final sub = container.listen(
            connectionConfigProvider,
            (_, next) => states.add(next),
          );
          addTearDown(sub.close);
          await container.read(connectionConfigProvider.future);
          final notifier = container.read(connectionConfigProvider.notifier);
          secure.calls.clear();
          states.clear();
          var effects = 0;
          secure.after = (method, key) async {
            if (method == 'write' || method == 'delete') {
              if (effects++ == stop) await home.choose(HomeSource.verifiedCore);
            }
          };
          await expectLater(
            signOut ? notifier.signOut() : notifier.signIn(replacement),
            throwsA(isA<DirectHomeAccessException>()),
          );
          expect(secure.calls, hasLength(stop + 1));
          expect(states.where((s) => s.hasValue), isEmpty);
          if (stop < 3) {
            expect(
              secure.values[CredentialsStore.pendingMutationKey],
              isNotNull,
            );
          }
        },
      );
    }
  }

  test(
    'explicit signIn repairs pending record and signOut clears it',
    () async {
      secure.values[CredentialsStore.pendingMutationKey] = '1';
      final (container, _) = await fixture.containerFor(HomeSource.directLocal);
      final sub = container.listen(connectionConfigProvider, (_, _) {});
      addTearDown(sub.close);
      await expectLater(
        container.read(connectionConfigProvider.future),
        throwsA(isA<DirectHomeAccessException>()),
      );
      final notifier = container.read(connectionConfigProvider.notifier);
      await notifier.signIn(replacement);
      expect(
        container.read(connectionConfigProvider).value?.token,
        replacement.token,
      );
      expect(secure.values[CredentialsStore.pendingMutationKey], isNull);
      await notifier.signOut();
      expect(container.read(connectionConfigProvider).value, isNull);
      expect(secure.values.keys.where((k) => k.startsWith('ha_')), isEmpty);
    },
  );

  for (final stopKey in ['jellyfin_base_url', 'jellyfin_device_id']) {
    test('credential seeding stops on Core switch during $stopKey', () async {
      final (container, home) = await fixture.containerFor(
        HomeSource.directLocal,
      );
      secure.after = (method, key) async {
        if (key == stopKey &&
            (stopKey != 'jellyfin_device_id' || method == 'write')) {
          await home.choose(HomeSource.verifiedCore);
        }
      };
      final sub = container.listen(enabledServicesProvider, (_, _) {});
      addTearDown(sub.close);
      await expectLater(
        container.read(enabledServicesProvider.future),
        throwsA(isA<Exception>()),
      );
      expect(secure.calls.last.$2, stopKey);
      expect(prefs.writes, isEmpty);
      expect(container.read(enabledServicesProvider).hasValue, isFalse);
    });
  }

  test(
    'source changes during preferences load prevents credential seed',
    () async {
      final (container, home) = await fixture.containerFor(
        HomeSource.directLocal,
      );
      prefs.afterRead = () => home.choose(HomeSource.verifiedCore);
      final sub = container.listen(enabledServicesProvider, (_, _) {});
      addTearDown(sub.close);
      await expectLater(
        container.read(enabledServicesProvider.future),
        throwsA(isA<Exception>()),
      );
      expect(secure.calls, isEmpty);
      expect(prefs.writes, isEmpty);
    },
  );

  test('Core migrationComplete does not even acquire preferences', () async {
    final (container, _) = await fixture.containerFor(HomeSource.verifiedCore);
    await expectLater(
      container.read(enabledServicesStoreProvider).migrationComplete(),
      throwsA(isA<DirectHomeAccessException>()),
    );
    expect(prefs.reads, 0);
    expect(prefs.writes, isEmpty);
  });

  test('Direct seeds each configured service once including scoped device ID write', () async {
    for (final name in [
      'jellyseerr',
      'sonarr',
      'radarr',
      'lidarr',
      'readarr',
      'bazarr',
      'prowlarr',
    ]) {
      secure.values['${name}_base_url'] = 'https://synthetic.invalid';
      secure.values['${name}_api_key'] = 'synthetic';
    }
    for (final name in ['qbittorrent', 'keenetic']) {
      secure.values['${name}_base_url'] = 'https://synthetic.invalid';
      secure.values['${name}_username'] = 'synthetic';
      secure.values['${name}_password'] = 'synthetic';
    }
    secure.values.addAll({
      'proxmox_host': 'synthetic.invalid',
      'proxmox_port': '8006',
      'proxmox_username': 'synthetic',
      'proxmox_realm': 'pam',
      'proxmox_password': 'synthetic',
      'proxmox_allow_self_signed': 'false',
    });
    final (container, home) = await fixture.containerFor(
      HomeSource.directLocal,
    );
    home.interaction.setActive(false);
    final sub = container.listen(enabledServicesProvider, (_, _) {});
    addTearDown(sub.close);
    expect(
      await container.read(enabledServicesProvider.future),
      AppService.values.toSet(),
    );
    expect(secure.calls.where((c) => c.$1 == 'write'), [
      ('write', 'jellyfin_device_id'),
    ]);
    secure.calls.clear();
    container.invalidate(enabledServicesProvider);
    expect(
      await container.read(enabledServicesProvider.future),
      AppService.values.toSet(),
    );
    expect(secure.calls, isEmpty);
  });

  for (final key in [
    'flutter.enabled_services',
    'flutter.enabled_services_migrated',
  ]) {
    for (final throws in [false, true]) {
      test(
        'failed seed $key ${throws ? 'throws' : 'false'} never publishes success',
        () async {
          if (throws) {
            prefs.throwKey = key;
          } else {
            prefs.falseKey = key;
          }
          final (container, _) = await fixture.containerFor(
            HomeSource.directLocal,
          );
          final sub = container.listen(enabledServicesProvider, (_, _) {});
          addTearDown(sub.close);
          await expectLater(
            container.read(enabledServicesProvider.future),
            throwsA(anything),
          );
          expect(container.read(enabledServicesProvider).hasValue, isFalse);
          expect(
            (await prefs.getAll())['flutter.enabled_services_migrated'],
            isNull,
          );
        },
      );
    }
  }

  test(
    'source loss after enabled list effect does not write migration flag',
    () async {
      final (container, home) = await fixture.containerFor(
        HomeSource.directLocal,
      );
      prefs.afterWrite = (key) async {
        if (key == 'flutter.enabled_services') {
          await home.choose(HomeSource.verifiedCore);
        }
      };
      final sub = container.listen(enabledServicesProvider, (_, _) {});
      addTearDown(sub.close);
      await expectLater(
        container.read(enabledServicesProvider.future),
        throwsA(isA<Exception>()),
      );
      expect(prefs.writes, ['flutter.enabled_services']);
      expect(
        (await prefs.getAll())['flutter.enabled_services_migrated'],
        isNull,
      );
    },
  );

  test(
    'setEnabled queues against persisted values and never clears credentials',
    () async {
      prefs = Preferences({
        'flutter.enabled_services_migrated': true,
        'flutter.enabled_services': <String>['jellyfin', 'unrecognized'],
      });
      SharedPreferencesStorePlatform.instance = prefs;
      final (container, _) = await fixture.containerFor(HomeSource.directLocal);
      final sub = container.listen(enabledServicesProvider, (_, _) {});
      addTearDown(sub.close);
      expect(await container.read(enabledServicesProvider.future), {
        AppService.jellyfin,
      });
      final notifier = container.read(enabledServicesProvider.notifier);
      await Future.wait([
        notifier.setEnabled(AppService.sonarr, true),
        notifier.setEnabled(AppService.jellyfin, false),
      ]);
      expect(container.read(enabledServicesProvider).value, {
        AppService.sonarr,
      });
      expect(secure.calls, isEmpty);
    },
  );

  test('queued setEnabled revoked before dispatch does not read or mutate preferences', () async {
    prefs = Preferences({'flutter.enabled_services_migrated': true});
    SharedPreferencesStorePlatform.instance = prefs;
    final (container, home) = await fixture.containerFor(
      HomeSource.directLocal,
    );
    final sub = container.listen(enabledServicesProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(enabledServicesProvider.future);
    final before = prefs.reads;
    final release = Completer<void>();
    final blocker = ConfigurationWrites.run(() => release.future);
    final waiting = expectLater(
      container
          .read(enabledServicesProvider.notifier)
          .setEnabled(AppService.sonarr, true),
      throwsA(isA<DirectHomeAccessException>()),
    );
    await home.choose(HomeSource.verifiedCore);
    release.complete();
    await blocker;
    await waiting;
    expect(prefs.reads, before);
    expect(prefs.writes, isEmpty);
  });
  for (final pending in [false, true]) {
    test(
      'actual HA client providers never construct transport for ${pending ? 'revoked pending read' : 'Core source'}',
      () async {
        var constructors = 0;
        final (container, home) = await fixture.containerFor(
          pending ? HomeSource.directLocal : HomeSource.verifiedCore,
          overrides: [
            haRestClientFactoryProvider.overrideWithValue((_, _) {
              constructors++;
              throw StateError('unexpected REST');
            }),
            haWebSocketClientFactoryProvider.overrideWithValue((_, _) {
              constructors++;
              throw StateError('unexpected WS');
            }),
          ],
        );
        final reached = Completer<void>(), release = Completer<void>();
        if (pending) {
          secure.after = (method, key) async {
            if (key == 'ha_base_url') {
              reached.complete();
              await release.future;
            }
          };
        }
        final rest = container.listen(haRestClientProvider, (_, _) {});
        final ws = container.listen(haWebSocketClientProvider, (_, _) {});
        addTearDown(rest.close);
        addTearDown(ws.close);
        final waiting = expectLater(
          container.read(connectionConfigProvider.future),
          throwsA(isA<Exception>()),
        );
        if (pending) {
          await reached.future;
          await home.choose(HomeSource.verifiedCore);
          release.complete();
        }
        await waiting;
        await Future<void>.delayed(Duration.zero);
        expect(rest.read(), isNull);
        expect(ws.read(), isNull);
        expect(constructors, 0);
        if (!pending) expect(secure.calls, isEmpty);
      },
    );
  }
}
