import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_vault_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_disclosure_policy.dart';

import '../backup/backup_test_storage.dart';
import 'server_vault_test_support.dart';

void main() {
  late VaultApi api;
  late ServerAccountController account;
  late MemoryBackupStorage storage;
  late ServerVaultController controller;
  late DateTime clock;
  late bool current;
  const all = BackupSelection(connections: true);
  Future<ServerVaultReview> prepare({
    ServerVaultDirection direction = ServerVaultDirection.upload,
    BackupSelection selection = const BackupSelection(),
    BackupConflictPolicy policy = BackupConflictPolicy.keepExisting,
  }) => controller.prepare(
    direction: direction,
    selection: selection,
    conflictPolicy: policy,
    access: direction == ServerVaultDirection.restore
        ? VaultRestoreAccess(isCurrent: () => current)
        : null,
  );

  Future<void> applyPrepared(
    PreparedBackupRestore prepared, {
    void Function()? afterClaim,
  }) async {
    final owner = Object();
    await prepared.checkBeforeHandoff();
    prepared.claimForHandoff(owner);
    afterClaim?.call();
    await prepared.applyAfterHandoff(owner, isCurrentBoundary: () => true);
  }

  setUp(() async {
    clock = DateTime.now();
    current = true;
    api = VaultApi();
    account = ServerAccountController(
      store: VaultAccountStore(
        value: vaultSession(expires: clock.add(const Duration(hours: 1))),
      ),
      apiFactory: (_) => api,
      clock: () => clock,
    );
    await account.initialize();
    storage = MemoryBackupStorage(
      preferences: {'appearance': 'light'},
      secrets: {
        'settings_pin': 'fixture-pin',
        'ha_base_url': 'https://local-fixture.invalid',
        'ha_token': 'synthetic_local_secret',
        'larenor_server_session_v1': 'synthetic_server_session',
        WellbeingDisclosureStore.storageKey: jsonEncode({
          'version': 1,
          'entityIds': ['sensor.local_private_fixture'],
          'reviewRequired': false,
        }),
      },
    );
    controller = ServerVaultController(
      account: account,
      repository: BackupRepository(storage: storage),
      isCurrent: () => current,
      clock: () => clock,
    );
  });
  tearDown(() {
    controller.dispose();
    account.dispose();
  });

  test(
    'preview is read-only; default upload omits credentials, PIN and session',
    () async {
      final review = await prepare();
      expect(review.revision, 7);
      expect(review.remote!.services, ['ha', 'proxmox']);
      expect(review.local.services, isEmpty);
      expect(review.selection.connections, isFalse);
      expect(storage.writes, isEmpty);
      expect(api.writes, 0);
      await controller.upload(review);
      expect(api.writes, 1);
      expect(api.expectedRevision, 7);
      final json = jsonEncode(api.uploaded!.toJson());
      expect(api.uploaded!.toJson()['version'], 2);
      expect(json, isNot(contains('synthetic_local_secret')));
      expect(json, isNot(contains('fixture-pin')));
      expect(json, isNot(contains('synthetic_access')));
      expect(json, isNot(contains('synthetic_server_session')));
      expect(json, contains('sensor.local_private_fixture'));
      expect(storage.writes, isEmpty);
    },
  );

  test(
    'credentials require explicit selection; intent and completion are one-use',
    () async {
      final review = await prepare(selection: all);
      expect(review.local.services, ['ha']);
      expect(review.toString(), isNot(contains('synthetic')));
      await controller.upload(review);
      expect(
        jsonEncode(api.uploaded!.toJson()),
        contains('synthetic_local_secret'),
      );
      await expectLater(
        controller.upload(review),
        throwsA(isA<LarenorServerException>()),
      );
      expect(api.writes, 1);
    },
  );

  test(
    'no saved vault and legacy remote snapshots never produce restore intents',
    () async {
      api.value = const ServerVault(revision: 0, snapshot: null);
      await expectLater(
        prepare(direction: ServerVaultDirection.restore),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'empty_vault',
          ),
        ),
      );
      api.value = ServerVault(
        revision: 1,
        snapshot: vaultSnapshot(legacy: true),
      );
      await expectLater(prepare(), throwsA(isA<LarenorServerException>()));
      expect(api.writes, 0);
      expect(storage.writes, isEmpty);
    },
  );

  test('empty selection never reads the server', () async {
    await expectLater(
      prepare(
        selection: const BackupSelection(settings: false, dashboard: false),
      ),
      throwsA(isA<LarenorServerException>()),
    );
    expect(api.reads, 0);
  });

  test('overlapping preview rejected; invalidated pending read cannot return a review', () async {
    api.pendingRead = Completer();
    final first = prepare();
    final expectation = expectLater(
      first,
      throwsA(isA<LarenorServerException>()),
    );
    await expectLater(
      prepare(),
      throwsA(
        isA<LarenorServerException>().having((e) => e.code, 'code', 'busy'),
      ),
    );
    controller.invalidate();
    api.pendingRead!.complete(api.value);
    await expectation;
    expect(api.reads, 1);
    expect(storage.reads, isEmpty);
    expect(storage.writes, isEmpty);
  });

  test('foreground and account loss reject retained confirmation', () async {
    final review = await prepare();
    current = false;
    await expectLater(
      controller.upload(review),
      throwsA(isA<LarenorServerException>()),
    );
    current = true;
    await account.signOut();
    await expectLater(
      controller.upload(review),
      throwsA(isA<LarenorServerException>()),
    );
    expect(api.writes, 0);
  });

  test(
    'five-minute and backwards-clock reviews expire before mutation',
    () async {
      final review = await prepare();
      clock = clock.add(const Duration(minutes: 5));
      await expectLater(
        controller.upload(review),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'review_expired',
          ),
        ),
      );
      final next = await prepare();
      clock = clock.subtract(const Duration(seconds: 1));
      await expectLater(
        controller.upload(next),
        throwsA(isA<LarenorServerException>()),
      );
      expect(api.writes, 0);
    },
  );

  for (final expire in [false, true]) {
    test(
      'token refresh completion rechecks ${expire ? 'deadline' : 'foreground'} before PUT',
      () async {
        controller.dispose();
        account.dispose();
        account = ServerAccountController(
          store: VaultAccountStore(
            value: vaultSession(expires: clock.add(const Duration(minutes: 2))),
          ),
          apiFactory: (_) => api,
          clock: () => clock,
        );
        await account.initialize();
        controller = ServerVaultController(
          account: account,
          repository: BackupRepository(storage: storage),
          isCurrent: () => current,
          clock: () => clock,
        );
        final review = await prepare();
        clock = clock.add(const Duration(minutes: 1, seconds: 50));
        api.pendingRefresh = Completer();
        final pending = controller.upload(review);
        final expectation = expectLater(
          pending,
          throwsA(isA<LarenorServerException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(api.refreshes, 1);
        if (expire) {
          clock = clock.add(const Duration(minutes: 4));
        } else {
          current = false;
        }
        api.pendingRefresh!.complete(
          vaultSession(expires: clock.add(const Duration(hours: 1))),
        );
        await expectation;
        expect(api.writes, 0);
      },
    );
  }

  for (final error in ['conflict', 'revision_conflict', 'timeout']) {
    test(
      '$error consumes confirmation without retry or local writes',
      () async {
        final review = await prepare();
        api.writeError = error;
        await expectLater(
          controller.upload(review),
          throwsA(isA<LarenorServerException>()),
        );
        await expectLater(
          controller.upload(review),
          throwsA(isA<LarenorServerException>()),
        );
        expect(api.writes, 1);
        expect(storage.writes, isEmpty);
        api.writeError = null;
        final next = await prepare();
        expect(api.reads, 2);
        await controller.upload(next);
        expect(api.writes, 2);
      },
    );
  }

  test(
    'in-flight PUT is single flight and stale completion is rejected',
    () async {
      final review = await prepare();
      api.pendingWrite = Completer();
      final write = controller.upload(review);
      final expectation = expectLater(
        write,
        throwsA(isA<LarenorServerException>()),
      );
      await expectLater(
        controller.upload(review),
        throwsA(isA<LarenorServerException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.writes, 1);
      controller.invalidate();
      api.pendingWrite!.complete(api.value);
      await expectation;
    },
  );

  test(
    'restore rechecks revision and refuses a changed server vault',
    () async {
      final review = await prepare(direction: ServerVaultDirection.restore);
      api.value = ServerVault(revision: 8, snapshot: vaultSnapshot());
      await expectLater(
        controller.takeRestore(review),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
      expect(api.reads, 2);
      expect(api.writes, 0);
      expect(storage.writes, isEmpty);
    },
  );

  for (final finalRead in [false, true]) {
    test(
      'retired ${finalRead ? 'final' : 'preview'} Vault GET cannot reject the current account with a late 401',
      () async {
        final review = finalRead
            ? await prepare(direction: ServerVaultDirection.restore)
            : null;
        api.pendingRead = Completer();
        final pending = finalRead
            ? controller.takeRestore(review!)
            : prepare(direction: ServerVaultDirection.restore);
        final rejected = expectLater(
          pending,
          throwsA(isA<LarenorServerException>()),
        );
        await Future<void>.delayed(Duration.zero);
        controller.invalidate();
        api.pendingRead!.completeError(
          const LarenorServerException('unauthorized'),
        );
        await rejected;
        expect(account.session, isNotNull);
        expect(account.failure, isNull);
        expect(storage.writes, isEmpty);
      },
    );
  }

  test('active Vault GET unauthorized still rejects the account', () async {
    api.readError = 'unauthorized';
    await expectLater(prepare(), throwsA(isA<LarenorServerException>()));
    expect(account.session, isNull);
    expect(account.failure, 'unauthorized');
  });

  test(
    'final Vault GET 401 after review expiry cannot reject the current account',
    () async {
      final review = await prepare(direction: ServerVaultDirection.restore);
      api.pendingRead = Completer();
      final pending = controller.takeRestore(review);
      final expired = expectLater(
        pending,
        throwsA(isA<LarenorServerException>()),
      );
      await Future<void>.delayed(Duration.zero);
      clock = clock.add(const Duration(minutes: 5));
      api.pendingRead!.completeError(
        const LarenorServerException('unauthorized'),
      );
      await expired;
      expect(account.session, isNotNull);
      expect(account.failure, isNull);
      expect(storage.writes, isEmpty);
    },
  );

  for (final policy in BackupConflictPolicy.values) {
    test(
      'restore $policy delegates local journal work after old controller disposal',
      () async {
        final review = await prepare(
          direction: ServerVaultDirection.restore,
          selection: all,
          policy: policy,
        );
        expect(review.remote!.requiresCertificateReview, isTrue);
        expect(review.remote!.requiresPrivacyReview, isTrue);
        final restore = await controller.takeRestore(review);
        expect(storage.writes, isEmpty);
        await applyPrepared(restore, afterClaim: controller.dispose);
        expect(
          storage.preferences['appearance'],
          policy == BackupConflictPolicy.keepExisting ? 'light' : 'dark',
        );
        expect(
          storage.secrets['ha_token'],
          policy == BackupConflictPolicy.keepExisting
              ? 'synthetic_local_secret'
              : 'synthetic_private_ha_secret',
        );
        expect(storage.secrets['settings_pin'], 'fixture-pin');
        expect(storage.secrets['proxmox_allow_self_signed'], 'false');
        final privacy = jsonDecode(
          storage.secrets[WellbeingDisclosureStore.storageKey]!,
        ) as Map;
        expect(
          privacy['entityIds'],
          containsAll([
            'sensor.private_fixture',
            'sensor.local_private_fixture',
          ]),
        );
        expect(
          storage.secrets['larenor_server_session_v1'],
          'synthetic_server_session',
        );
        expect(
          storage.secrets,
          isNot(contains(BackupRepository.restoreJournalKey)),
        );
        final count = storage.writeCount;
        await expectLater(
          applyPrepared(restore),
          throwsA(isA<BackupException>()),
        );
        expect(storage.writeCount, count);
        expect(api.writes, 0);
      },
    );
  }

  test(
    'failed local restore follows repository rollback and preserves PIN',
    () async {
      final review = await prepare(
        direction: ServerVaultDirection.restore,
        policy: BackupConflictPolicy.replaceSelected,
      );
      final restore = await controller.takeRestore(review);
      storage.failWrites.add(3);
      await expectLater(
        applyPrepared(restore),
        throwsA(isA<BackupException>()),
      );
      expect(storage.preferences['appearance'], 'light');
      expect(storage.secrets['settings_pin'], 'fixture-pin');
    },
  );
}
