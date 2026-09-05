import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/settings/providers/window_profile_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements WindowProfileStore {
  Object? value;
  bool fail = false;
  int writes = 0;
  Completer<void>? wait;
  @override
  Future<Object?> read() async => value;
  @override
  Future<void> write(WindowProfile profile) async {
    writes++;
    await wait?.future;
    if (fail) throw StateError('storage failed');
    value = profile.name;
  }
}

void main() {
  for (final value in [null, 'unknown', 'locked', true, 42, 'panel']) {
    test('stored profile $value has a safe typed interpretation', () async {
      SharedPreferences.setMockInitialValues({
        windowProfilePreferenceKey: ?value,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await container.read(windowProfileProvider.future),
        value == 'panel' ? WindowProfile.panel : WindowProfile.adaptive,
      );
    });
  }

  test(
    'failed save never claims panel mode; successful save survives reload',
    () async {
      final store = _Store();
      final container = ProviderContainer(
        overrides: [windowProfileStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(windowProfileProvider.future);
      store.fail = true;
      await expectLater(
        container.read(windowProfileProvider.notifier).set(WindowProfile.panel),
        throwsStateError,
      );
      expect(
        container.read(windowProfileProvider).value,
        WindowProfile.adaptive,
      );
      store.fail = false;
      await container
          .read(windowProfileProvider.notifier)
          .set(WindowProfile.panel);
      container.invalidate(windowProfileProvider);
      expect(
        await container.read(windowProfileProvider.future),
        WindowProfile.panel,
      );
    },
  );

  test(
    'queued write is cancelled if its configuration scope is disposed',
    () async {
      final store = _Store();
      final container = ProviderContainer(
        overrides: [windowProfileStoreProvider.overrideWithValue(store)],
      );
      await container.read(windowProfileProvider.future);
      final blocker = Completer<void>();
      final pending = ConfigurationWrites.run(() => blocker.future);
      final write = container
          .read(windowProfileProvider.notifier)
          .set(WindowProfile.panel);
      container.dispose();
      blocker.complete();
      await pending;
      await write;
      expect(store.writes, 0);
    },
  );

  test(
    'rapid profile choices save serially and do not publish early',
    () async {
      final store = _Store()..wait = Completer<void>();
      final container = ProviderContainer(
        overrides: [windowProfileStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(windowProfileProvider.future);
      final notifier = container.read(windowProfileProvider.notifier);
      final first = notifier.set(WindowProfile.panel);
      final second = notifier.set(WindowProfile.adaptive);
      expect(
        container.read(windowProfileProvider).value,
        WindowProfile.adaptive,
      );
      expect(store.writes, 1);
      store.wait!.complete();
      await first;
      await second;
      expect(store.writes, 2);
      expect(store.value, 'adaptive');
      expect(
        container.read(windowProfileProvider).value,
        WindowProfile.adaptive,
      );
    },
  );

  test(
    'vault allows appearance profiles but rejects managed-mode injection',
    () {
      BackupSnapshot snapshot(Object profile) => BackupSnapshot.fromJson({
        'version': 1,
        'createdAt': '2026-09-05T00:00:00Z',
        'groups': {
          'settings': {'window_profile': profile},
        },
      });
      for (final profile in ['adaptive', 'panel']) {
        expect(snapshot(profile).toJson()['groups'], {
          'settings': {'window_profile': profile},
        });
      }
      for (final invalid in ['locked', 'deviceOwner', true, 1]) {
        expect(
          () => snapshot(invalid),
          throwsA(isA<BackupValidationException>()),
        );
      }
    },
  );
}
