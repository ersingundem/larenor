import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_credential_store.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_profile_store.dart';
import 'package:larenor/features/server/tablet_fleet/domain/server_tablet_fleet_models.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/settings/providers/window_profile_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const coreId = 'a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0';
const homeId = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
const deviceId = 'c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0';

ManagedTabletBinding binding() => ManagedTabletBinding(
  serverBaseUrl: 'https://core.example.test',
  coreId: coreId,
  homeId: homeId,
  accountId: 'account-1',
);

ManagedTabletProfilePublication publication({
  int deviceRevision = 2,
  int revision = 2,
  bool fullscreen = true,
  int idleTimeoutSeconds = 300,
  String? digest,
}) {
  final expected = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            1,
            coreId,
            homeId,
            deviceId,
            fullscreen,
            idleTimeoutSeconds,
          ]),
        ),
      )
      .toString();
  return ManagedTabletProfilePublication.fromJson({
    'publication': {
      'schemaVersion': 1,
      'deviceId': deviceId,
      'deviceRevision': deviceRevision,
      'revision': revision,
      'digest': digest ?? expected,
      'document': {
        'schemaVersion': 1,
        'fullscreen': fullscreen,
        'idleTimeoutSeconds': idleTimeoutSeconds,
      },
      'updatedAt': 1789977600.0 + revision,
    },
  });
}

final class _Persistence implements ManagedTabletProfilePersistence {
  String? value;
  Completer<void>? nextWrite;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? value) async {
    writes++;
    final gate = nextWrite;
    nextWrite = null;
    await gate?.future;
    this.value = value;
  }
}

void main() {
  test('exact profile is one durable document and survives reload', () async {
    final persistence = _Persistence();
    final store = ManagedTabletProfileStore(persistence);

    final applied = await store.apply(
      binding(),
      publication(),
      expectedDeviceId: deviceId,
      isCurrent: () => true,
    );
    final reloaded = await ManagedTabletProfileStore(persistence).read();

    expect(applied.revision, 2);
    expect(applied.fullscreen, isTrue);
    expect(applied.idleTimeoutSeconds, 300);
    expect(reloaded?.digest, applied.digest);
    expect(persistence.writes, 1);
    expect(persistence.value, isNot(contains('serverBaseUrl')));
    expect(persistence.value, isNot(contains('account-1')));
  });

  test(
    'same publication is idempotent; rollback and conflict fail closed',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      await store.apply(
        binding(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );

      await store.apply(
        binding(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      expect(persistence.writes, 1);
      await expectLater(
        store.apply(
          binding(),
          publication(deviceRevision: 3, revision: 1),
          expectedDeviceId: deviceId,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await expectLater(
        store.apply(
          binding(),
          publication(deviceRevision: 2, revision: 2, fullscreen: false),
          expectedDeviceId: deviceId,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect((await store.read())?.revision, 2);
    },
  );

  test(
    'retirement during persistence restores the previous document',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      await store.apply(
        binding(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      final previous = persistence.value;
      final gate = Completer<void>();
      persistence.nextWrite = gate;
      var current = true;

      final pending = store.apply(
        binding(),
        publication(deviceRevision: 3, revision: 3, fullscreen: false),
        expectedDeviceId: deviceId,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      gate.complete();

      await expectLater(pending, throwsStateError);
      expect(persistence.value, previous);
      expect((await store.read())?.revision, 2);
    },
  );

  test(
    'tampered durable digest is rejected before settings can read it',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      final applied = await store.apply(
        binding(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      final raw = jsonDecode(persistence.value!) as Map<String, dynamic>;
      persistence.value = jsonEncode({...raw, 'digest': '0' * 64});

      await expectLater(store.read(), throwsStateError);
      expect(applied.toString(), isNot(contains(coreId)));
    },
  );

  test(
    'managed profile atomically owns fullscreen and exact idle timeout',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = ManagedTabletProfileStore(
        SharedPreferencesManagedTabletProfilePersistence(),
      );
      await store.apply(
        binding(),
        publication(idleTimeoutSeconds: 30),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        await container.read(windowProfileProvider.future),
        WindowProfile.panel,
      );
      final idle = await container.read(idleModeProvider.future);
      expect(idle.enabled, isTrue);
      expect(idle.timeoutSeconds, 30);
      expect(idle.timeoutMinutes, 1);
      await expectLater(
        container
            .read(windowProfileProvider.notifier)
            .set(WindowProfile.adaptive),
        throwsStateError,
      );
      await expectLater(
        container.read(idleModeProvider.notifier).setEnabled(false),
        throwsStateError,
      );
    },
  );
}
