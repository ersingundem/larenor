import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Uses the pinned plugin's public platform seam, never real secure storage.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_disclosure_policy.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_store.dart';
import 'package:larenor/features/wellbeing/domain/wellbeing_models.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_privacy_providers.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/direct_home_boundary_test.dart' as home;
import '../../core/direct_home_routines_test.dart' show routinesHome;
import 'wellbeing_controller_test.dart' show FakeNative;
import 'wellbeing_data_test.dart' show binding;

final _private = WellbeingSettings(
  enabled: true,
  profileLabel: 'Synthetic private person',
  nativeMetrics: {WellbeingMetric.steps},
  bindings: [binding()],
);
final _restricted = WellbeingDisclosurePolicy(
  entityIds: {'sensor.other_scale'},
);
const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

class _Secure extends home.SecurePlatform {
  final failedReads = <String>{};
  bool failWrite = false;
  bool failAfterEffect = false;
  void Function()? afterEffect;
  @override
  Future<Object?> handle(MethodCall call) async {
    final key = (call.arguments as Map)['key'];
    if (call.method == 'read' && failedReads.contains(key)) {
      throw PlatformException(code: 'private-read', message: 'private detail');
    }
    final mutation = call.method == 'write' || call.method == 'delete';
    if (mutation && failWrite && !failAfterEffect) {
      throw PlatformException(code: 'private-write', message: 'private detail');
    }
    final result = await super.handle(call);
    if (mutation) {
      afterEffect?.call();
      if (failWrite && failAfterEffect) {
        throw PlatformException(
          code: 'private-write',
          message: 'private detail',
        );
      }
    }
    return result;
  }
}

Future<void> _ready(ProviderContainer c) async {
  await c.read(wellbeingSettingsProvider.future);
  await c.read(wellbeingDisclosureProvider.future);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Secure secure;
  late FlutterSecureStoragePlatform previous;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = _Secure();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, secure.handle);
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  for (final mode in ['direct', 'core', 'pending', 'error']) {
    test(
      '$mode retains device privacy restrictions without acquiring HA credentials',
      () async {
        secure.values[WellbeingStore.storageKey] = jsonEncode(
          WellbeingStore.encode(_private),
        );
        secure.values[WellbeingDisclosureStore.storageKey] = jsonEncode(
          _restricted.toJson(),
        );
        final (c, _) = await routinesHome(mode);
        await _ready(c);
        expect(c.read(wellbeingPrivateEntityIdsProvider).requireValue, {
          'sensor.scale',
          'sensor.other_scale',
        });
        expect(
          c.read(wellbeingSettingsProvider).requireValue.profileLabel,
          'Synthetic private person',
        );
        expect(secure.calls.map((e) => e.$2).toSet(), {
          WellbeingStore.storageKey,
          WellbeingDisclosureStore.storageKey,
        });
        expect(secure.calls.where((e) => e.$1 != 'read'), isEmpty);
      },
    );
    for (final key in [
      WellbeingStore.storageKey,
      WellbeingDisclosureStore.storageKey,
    ]) {
      test(
        '$mode unreadable $key never becomes a public empty privacy filter',
        () async {
          secure.failedReads.add(key);
          final (c, _) = await routinesHome(mode);
          try {
            await _ready(c);
          } catch (_) {}
          // Ensure both real reads finish, irrespective of the failing key's order.
          try {
            await c.read(wellbeingDisclosureProvider.future);
          } catch (_) {}
          final privacy = c.read(wellbeingPrivateEntityIdsProvider);
          expect(privacy.hasError, isTrue);
          expect(privacy.value, isNull);
          expect(isPublicHaEntity(privacy, 'sensor.scale'), isFalse);
        },
      );
    }
  }

  for (final operation in ['settings', 'disclosure', 'clear']) {
    for (final after in [false, true]) {
      test(
        '$operation uncertain platform write (afterEffect=$after) closes the global privacy filter',
        () async {
          final (c, _) = await routinesHome('core');
          await _ready(c);
          expect(
            isPublicHaEntity(
              c.read(wellbeingPrivateEntityIdsProvider),
              'sensor.scale',
            ),
            isTrue,
          );
          secure.failWrite = true;
          secure.failAfterEffect = after;
          final action = switch (operation) {
            'settings' =>
              c
                  .read(wellbeingSettingsProvider.notifier)
                  .save(_private, isCurrent: () => true),
            'disclosure' =>
              c
                  .read(wellbeingDisclosureProvider.notifier)
                  .save(_restricted, isCurrent: () => true),
            _ =>
              c
                  .read(wellbeingSettingsProvider.notifier)
                  .clear(isCurrent: () => true),
          };
          await expectLater(action, throwsA(isA<WellbeingException>()));
          final privacy = c.read(wellbeingPrivateEntityIdsProvider);
          expect(privacy.hasError, isTrue);
          expect(privacy.value, isNull);
          expect(isPublicHaEntity(privacy, 'sensor.scale'), isFalse);
          final mutations = secure.calls.where((e) => e.$1 != 'read').toList();
          expect(mutations.length, after ? 1 : 0); // No rollback or retry.
          secure.failWrite = false;
          c.invalidate(wellbeingSettingsProvider);
          c.invalidate(wellbeingDisclosureProvider);
          await _ready(c);
          expect(c.read(wellbeingPrivateEntityIdsProvider).hasError, isFalse);
          expect(
            secure.calls.where((e) => e.$1 != 'read').length,
            mutations.length,
          );
        },
      );
    }
    test(
      '$operation cannot publish a response after its action authority expires',
      () async {
        final (c, _) = await routinesHome('direct');
        await _ready(c);
        var current = true;
        secure.afterEffect = () => current = false;
        await expectLater(switch (operation) {
          'settings' =>
            c
                .read(wellbeingSettingsProvider.notifier)
                .save(_private, isCurrent: () => current),
          'disclosure' =>
            c
                .read(wellbeingDisclosureProvider.notifier)
                .save(_restricted, isCurrent: () => current),
          _ =>
            c
                .read(wellbeingSettingsProvider.notifier)
                .clear(isCurrent: () => current),
        }, throwsA(isA<WellbeingException>()));
        expect(c.read(wellbeingPrivateEntityIdsProvider).hasError, isTrue);
        expect(
          isPublicHaEntity(
            c.read(wellbeingPrivateEntityIdsProvider),
            'sensor.scale',
          ),
          isFalse,
        );
        expect(secure.calls.where((e) => e.$1 != 'read').length, 1);
      },
    );
  }

  for (final operation in ['save', 'clear', 'disclosure']) {
    test(
      '$operation rejects a throwing private action as a static error before storage',
      () async {
        bool current() => throw StateError('synthetic private callback');
        await expectLater(
          switch (operation) {
            'save' => WellbeingStore().save(_private, isCurrent: current),
            'clear' => WellbeingStore().clear(isCurrent: current),
            _ => WellbeingDisclosureStore().save(
              _restricted,
              isCurrent: current,
            ),
          },
          throwsA(
            isA<WellbeingException>().having(
              (e) => e.toString(),
              'safe',
              isNot(contains('synthetic private')),
            ),
          ),
        );
        expect(secure.calls, isEmpty);
      },
    );
  }

  test(
    'Core identity alone cannot construct a native health query controller',
    () async {
      final native = FakeNative();
      final (c, _) = await home.containerFor(
        HomeSource.verifiedCore,
        overrides: [wellbeingNativeApiProvider.overrideWithValue(native)],
      );
      await _ready(c);
      expect(c.read(wellbeingAccessProvider), isNull);
      expect(c.read(wellbeingControllerProvider), isNull);
      expect(c.read(haWellbeingApiProvider), isNull);
      expect(native.probes + native.reads + native.permissions, 0);
      expect(secure.calls.where((e) => e.$2 == 'ha_token'), isEmpty);
    },
  );

  test('an explicit private session can use device-native health under Core without HA transport', () async {
    secure.values[WellbeingStore.storageKey] = jsonEncode(
      WellbeingStore.encode(_private),
    );
    final native = FakeNative();
    var current = true;
    final (c, _) = await home.containerFor(
      HomeSource.verifiedCore,
      overrides: [
        wellbeingNativeApiProvider.overrideWithValue(native),
        wellbeingAccessProvider.overrideWithValue(
          WellbeingAccessSession(isCurrent: () => current),
        ),
      ],
    );
    await _ready(c);
    c.read(haWellbeingApiProvider);
    await expectLater(
      c.read(connectionConfigProvider.future),
      throwsA(isA<Exception>()),
    );
    final controller = c.read(wellbeingControllerProvider)!;
    controller.setVisible(true);
    await controller.refresh();
    expect(native.reads, 1);
    expect(native.permissions, 0);
    expect(controller.haApi, isNull);
    expect(
      secure.calls.where((e) => e.$2 == 'ha_token' || e.$2 == 'ha_base_url'),
      isEmpty,
    );
    current = false;
    await controller.refresh();
    await controller.requestNativePermissions({WellbeingMetric.steps});
    expect(native.reads, 1);
    expect(native.permissions, 0);
  });

  test('normal backup contains display restrictions but no personal profile or native measurements', () async {
    secure.values[WellbeingStore.storageKey] = jsonEncode(
      WellbeingStore.encode(_private),
    );
    secure.values[WellbeingDisclosureStore.storageKey] = jsonEncode(
      _restricted.toJson(),
    );
    final backup = (await BackupRepository().capture(const BackupSelection()))
        .toJson();
    final text = jsonEncode(backup);
    expect(text, isNot(contains('Synthetic private person')));
    expect(text, isNot(contains('accountFingerprint')));
    expect(text, isNot(contains('nativeMetrics')));
    expect(text, isNot(contains(WellbeingStore.storageKey)));
    expect((backup['groups'] as Map)['privacy'], {
      'version': 1,
      'entityIds': ['sensor.other_scale', 'sensor.scale'],
      'reviewRequired': false,
    });
    expect(backupPreferenceKeys, isNot(contains(WellbeingStore.storageKey)));
  });
}
