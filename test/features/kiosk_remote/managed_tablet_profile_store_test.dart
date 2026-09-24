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

ManagedTabletEnrollment enrollment({
  String serverBaseUrl = 'https://core.example.test',
  String accountId = 'account-1',
  String pairingId = 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0',
  int revision = 1,
}) => ManagedTabletEnrollment(
  serverBaseUrl: serverBaseUrl,
  coreId: coreId,
  homeId: homeId,
  accountId: accountId,
  pairingId: pairingId,
  deviceId: deviceId,
  revision: revision,
  scopes: const {'read', 'control'},
  expiresAt: DateTime.utc(2030),
  token: 'A' * 43,
  clientId: 'larenor-$pairingId',
  topicPrefix: 'larenor/$pairingId',
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
  int? failAtWrite;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? value) async {
    writes++;
    if (writes == failAtWrite) throw StateError('scheduled_write_failure');
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
      enrollment(),
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
    expect(persistence.value, isNot(contains(enrollment().pairingId)));
  });

  test('profile authority includes endpoint account pairing and revision', () {
    final exact = enrollment();
    final applied = AppliedManagedTabletProfile.fromPublication(
      exact,
      publication(),
    );

    expect(applied.belongsTo(exact), isTrue);
    expect(
      applied.belongsTo(
        enrollment(serverBaseUrl: 'https://other-core.example.test'),
      ),
      isFalse,
    );
    expect(applied.belongsTo(enrollment(accountId: 'account-2')), isFalse);
    expect(applied.belongsTo(enrollment(pairingId: 'e0' * 16)), isFalse);
    expect(applied.belongsTo(enrollment(revision: 2)), isFalse);
  });

  test(
    'restart restore returns only an exact secure authority match',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      final exact = enrollment();
      await store.apply(
        exact,
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );

      expect((await store.readFor(exact))?.revision, 2);
      expect(await store.readFor(enrollment(accountId: 'account-2')), isNull);
      expect(await store.readFor(enrollment(pairingId: 'e0' * 16)), isNull);
    },
  );

  test(
    'foreign authority is cleared and never activated by rollback',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      await store.apply(
        enrollment(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      final foreign = enrollment(
        serverBaseUrl: 'https://other-core.example.test',
        accountId: 'account-2',
        pairingId: 'e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0',
      );
      final activations = <int?>[];

      await expectLater(
        store.apply(
          foreign,
          publication(deviceRevision: 3, revision: 3, fullscreen: false),
          expectedDeviceId: deviceId,
          isCurrent: () => true,
          activate: (profile) async {
            activations.add(profile?.revision);
            if (profile != null) throw StateError('activation_failed');
          },
        ),
        throwsStateError,
      );

      expect(activations, [3, null]);
      expect(persistence.value, isNull);
    },
  );

  test(
    'rollback still clears effective authority when persistence rollback fails',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      final activations = <int?>[];
      persistence.failAtWrite = 2;

      await expectLater(
        store.apply(
          enrollment(),
          publication(),
          expectedDeviceId: deviceId,
          isCurrent: () => true,
          activate: (profile) async {
            activations.add(profile?.revision);
            if (profile != null) throw StateError('activation_failed');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'managed_tablet_profile_rollback_failed',
          ),
        ),
      );
      expect(activations, [2, null]);
    },
  );

  test(
    'same publication is idempotent; rollback and conflict fail closed',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      await store.apply(
        enrollment(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );

      await store.apply(
        enrollment(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      expect(persistence.writes, 1);
      await expectLater(
        store.apply(
          enrollment(),
          publication(deviceRevision: 3, revision: 1),
          expectedDeviceId: deviceId,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await expectLater(
        store.apply(
          enrollment(),
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
        enrollment(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      final previous = persistence.value;
      final gate = Completer<void>();
      persistence.nextWrite = gate;
      var current = true;

      final pending = store.apply(
        enrollment(),
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
    'activation failure restores both durable and effective profile',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      await store.apply(
        enrollment(),
        publication(),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      final activations = <int?>[];

      await expectLater(
        store.apply(
          enrollment(),
          publication(deviceRevision: 3, revision: 3, fullscreen: false),
          expectedDeviceId: deviceId,
          isCurrent: () => true,
          activate: (profile) async {
            activations.add(profile?.revision);
            if (profile?.revision == 3) throw StateError('activation_failed');
          },
        ),
        throwsStateError,
      );

      expect(activations, [3, 2]);
      expect((await store.read())?.revision, 2);
    },
  );

  test(
    'tampered durable digest is rejected before settings can read it',
    () async {
      final persistence = _Persistence();
      final store = ManagedTabletProfileStore(persistence);
      final applied = await store.apply(
        enrollment(),
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
      final applied = await store.apply(
        enrollment(),
        publication(idleTimeoutSeconds: 30),
        expectedDeviceId: deviceId,
        isCurrent: () => true,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(managedTabletActiveProfileProvider.notifier)
          .activate(applied);

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

  test('durable profile alone cannot lock local settings', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ManagedTabletProfileStore(
      SharedPreferencesManagedTabletProfilePersistence(),
    );
    await store.apply(
      enrollment(),
      publication(idleTimeoutSeconds: 30),
      expectedDeviceId: deviceId,
      isCurrent: () => true,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container.read(windowProfileProvider.future),
      WindowProfile.adaptive,
    );
    expect((await container.read(idleModeProvider.future)).enabled, isFalse);
    await container
        .read(windowProfileProvider.notifier)
        .set(WindowProfile.panel);
  });
}
