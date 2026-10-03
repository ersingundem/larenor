import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_security_store.dart';

RdpSchema6SecretScope scope([int revision = 1]) => RdpSchema6SecretScope(
  namespaceDigest: ''.padLeft(64, 'a'),
  profileRef: ''.padLeft(64, 'b'),
  profileRevision: revision,
);

final class _FaultStorage extends FlutterSecureStorage {
  _FaultStorage();

  final values = <String, String>{};
  bool Function(String key, String? value)? failWriteBefore;
  bool Function(String key, String? value)? failWriteAfter;
  bool Function(String key)? failDeleteBefore;
  void Function(String key)? afterWrite;
  void Function(String key)? afterRead;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWriteBefore?.call(key, value) == true) throw StateError('write');
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    afterWrite?.call(key);
    if (failWriteAfter?.call(key, value) == true) throw StateError('write');
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final value = values[key];
    afterRead?.call(key);
    return value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failDeleteBefore?.call(key) == true) throw StateError('delete');
    values.remove(key);
  }
}

bool _secretKey(String value) => value.startsWith('rdp_schema6_secret_v1_');
bool _currentKey(String value) =>
    value.startsWith('rdp_schema6_current_secret_v1_');
bool _cleanupDebtKey(String value) =>
    value.startsWith('rdp_schema6_secret_cleanup_v1_');
bool _candidateDebtKey(String value) =>
    value.startsWith('rdp_schema6_secret_candidate_cleanup_v1_');
bool _retirementKey(String value) =>
    value.startsWith('rdp_schema6_secret_retirements_v1_');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('separate device refs resolve only in exact scope and kind', () async {
    final vault = RdpSchema6SecureSecretVault();
    final targetBytes = Uint8List.fromList([1, 2, 3]);
    final target = await vault.save(
      scope: scope(),
      kind: RdpSchema6SecretKind.targetPassword,
      secret: targetBytes,
      isCurrent: () => true,
    );
    expect(targetBytes, [0, 0, 0]);
    final gateway = await vault.save(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([4, 5, 6]),
      isCurrent: () => true,
    );
    expect(target, isNot(gateway));
    final resolved = await vault.resolve(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      reference: gateway,
      isCurrent: () => true,
    );
    expect(resolved.bytes, [4, 5, 6]);
    await expectLater(
      vault.resolve(
        scope: scope(2),
        kind: RdpSchema6SecretKind.gatewayPassword,
        reference: gateway,
        isCurrent: () => true,
      ),
      throwsA(
        isA<RdpFailure>().having(
          (value) => value.code,
          'code',
          'invalid_record',
        ),
      ),
    );
    await expectLater(
      vault.resolve(
        scope: scope(),
        kind: RdpSchema6SecretKind.targetPassword,
        reference: gateway,
        isCurrent: () => true,
      ),
      throwsA(isA<RdpFailure>()),
    );
  });

  test('delete and stale write are fail closed', () async {
    final vault = RdpSchema6SecureSecretVault();
    final reference = await vault.save(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([1]),
      isCurrent: () => true,
    );
    await vault.delete(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      reference: reference,
      isCurrent: () => true,
    );
    await expectLater(
      vault.resolve(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        reference: reference,
        isCurrent: () => true,
      ),
      throwsA(isA<RdpFailure>()),
    );
    await expectLater(
      vault.save(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([1]),
        isCurrent: () => false,
      ),
      throwsA(
        isA<RdpFailure>().having((value) => value.code, 'code', 'retired'),
      ),
    );
  });

  test('current gateway secret rotates by exact device-only scope', () async {
    final vault = RdpSchema6SecureSecretVault();
    final first = await vault.saveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([1, 2]),
      isCurrent: () => true,
    );
    final second = await vault.saveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([3, 4]),
      isCurrent: () => true,
    );
    expect(second, isNot(first));
    final current = await vault.resolveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      isCurrent: () => true,
    );
    expect(current!.bytes, [3, 4]);
    await expectLater(
      vault.resolve(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        reference: first,
        isCurrent: () => true,
      ),
      throwsA(isA<RdpFailure>()),
    );
    expect(
      await vault.resolveCurrent(
        scope: scope(2),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      ),
      isNull,
    );
    await vault.deleteCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      isCurrent: () => true,
    );
    expect(
      await vault.resolveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      ),
      isNull,
    );
  });

  test(
    'created-secret cleanup remains deletion-only after read authority retires',
    () async {
      final vault = RdpSchema6SecureSecretVault();
      var current = true;
      final owned = await vault.saveOwned(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([7, 8, 9]),
        isCurrent: () => current,
      );
      current = false;

      await expectLater(
        vault.resolve(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          reference: owned.reference,
          isCurrent: () => current,
        ),
        throwsA(
          isA<RdpFailure>().having((value) => value.code, 'code', 'retired'),
        ),
      );
      await owned.delete();
      await owned.delete();
      await expectLater(
        vault.resolve(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          reference: owned.reference,
          isCurrent: () => true,
        ),
        throwsA(
          isA<RdpFailure>().having(
            (value) => value.code,
            'code',
            'secret_unavailable',
          ),
        ),
      );
    },
  );

  test('old-scope cleanup cannot delete a newer current publication', () async {
    final vault = RdpSchema6SecureSecretVault();
    final first = await vault.saveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([1, 2]),
      isCurrent: () => true,
    );
    final cleanup = await vault.ownCurrentForCleanup(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      isCurrent: () => true,
    );
    expect(cleanup?.reference, first);
    final second = await vault.saveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([3, 4]),
      isCurrent: () => true,
    );

    await cleanup!.delete();

    final current = await vault.resolveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      isCurrent: () => true,
    );
    expect(current?.bytes, [3, 4]);
    expect(second, isNot(first));
    await expectLater(
      vault.resolve(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        reference: first,
        isCurrent: () => true,
      ),
      throwsA(isA<RdpFailure>()),
    );
  });

  test(
    'old revision cleanup preserves the new revision current secret',
    () async {
      final vault = RdpSchema6SecureSecretVault();
      await vault.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([1, 2]),
        isCurrent: () => true,
      );
      final oldCleanup = await vault.ownCurrentForCleanup(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );
      await vault.saveCurrent(
        scope: scope(2),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([8, 9]),
        isCurrent: () => true,
      );

      await oldCleanup!.delete();

      expect(
        await vault.resolveCurrent(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          isCurrent: () => true,
        ),
        isNull,
      );
      final current = await vault.resolveCurrent(
        scope: scope(2),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );
      expect(current?.bytes, [8, 9]);
    },
  );

  test('write-then-throw erases the exact newly created secret', () async {
    final storage = _FaultStorage();
    var failed = false;
    storage.failWriteAfter = (key, _) {
      if (!failed && _secretKey(key)) {
        failed = true;
        return true;
      }
      return false;
    };
    final vault = RdpSchema6SecureSecretVault(storage: storage);
    final bytes = Uint8List.fromList([1, 2, 3]);

    await expectLater(
      vault.save(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: bytes,
        isCurrent: () => true,
      ),
      throwsA(
        isA<RdpFailure>().having(
          (value) => value.code,
          'code',
          'storage_failed',
        ),
      ),
    );

    expect(bytes, [0, 0, 0]);
    expect(storage.values, isEmpty);
  });

  test(
    'retirement during intent handoff keeps failed deletion discoverable',
    () async {
      final storage = _FaultStorage();
      var current = true;
      var intentWrites = 0;
      storage.afterWrite = (key) {
        if (_candidateDebtKey(key) && ++intentWrites == 2) current = false;
      };
      storage.failDeleteBefore = _secretKey;
      final vault = RdpSchema6SecureSecretVault(storage: storage);

      await expectLater(
        vault.saveOwned(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          secret: Uint8List.fromList([9, 8]),
          isCurrent: () => current,
        ),
        throwsA(
          isA<RdpFailure>().having(
            (value) => value.code,
            'code',
            'storage_failed',
          ),
        ),
      );
      expect(storage.values.keys.where(_candidateDebtKey), hasLength(1));
      expect(storage.values.keys.where(_secretKey), hasLength(1));

      storage.afterWrite = null;
      storage.failDeleteBefore = null;
      final restarted = RdpSchema6SecureSecretVault(storage: storage);
      await expectLater(
        restarted.saveOwned(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          secret: Uint8List.fromList([1]),
          isCurrent: () => false,
        ),
        throwsA(
          isA<RdpFailure>().having((value) => value.code, 'code', 'retired'),
        ),
      );
      expect(storage.values, isEmpty);
    },
  );

  test(
    'first pointer commit uncertainty retains candidate until restart',
    () async {
      final storage = _FaultStorage();
      var pointerWriteFailed = false;
      storage.failWriteAfter = (key, _) {
        if (!pointerWriteFailed && _currentKey(key)) {
          pointerWriteFailed = true;
          return true;
        }
        return false;
      };
      storage.failDeleteBefore = _secretKey;
      final vault = RdpSchema6SecureSecretVault(storage: storage);

      await expectLater(
        vault.saveCurrent(
          scope: scope(),
          kind: RdpSchema6SecretKind.targetPassword,
          secret: Uint8List.fromList([4, 2]),
          isCurrent: () => true,
        ),
        throwsA(
          isA<RdpFailure>().having(
            (value) => value.code,
            'code',
            'storage_failed',
          ),
        ),
      );
      expect(storage.values.keys.where(_candidateDebtKey), hasLength(1));
      expect(storage.values.keys.where(_secretKey), hasLength(1));
      expect(storage.values.keys.where(_currentKey), isEmpty);

      storage.failWriteAfter = null;
      storage.failDeleteBefore = null;
      final restarted = RdpSchema6SecureSecretVault(storage: storage);
      expect(
        await restarted.resolveCurrent(
          scope: scope(),
          kind: RdpSchema6SecretKind.targetPassword,
          isCurrent: () => true,
        ),
        isNull,
      );
      expect(storage.values, isEmpty);
    },
  );

  test(
    'temporary write and delete uncertainty remains durably discoverable',
    () async {
      final storage = _FaultStorage();
      var writeFailed = false;
      storage.failWriteAfter = (key, _) {
        if (!writeFailed && _secretKey(key)) {
          writeFailed = true;
          return true;
        }
        return false;
      };
      storage.failDeleteBefore = _secretKey;
      final vault = RdpSchema6SecureSecretVault(storage: storage);

      await expectLater(
        vault.save(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          secret: Uint8List.fromList([3, 4, 5]),
          isCurrent: () => true,
        ),
        throwsA(
          isA<RdpFailure>().having(
            (value) => value.code,
            'code',
            'storage_failed',
          ),
        ),
      );
      expect(storage.values.keys.where(_candidateDebtKey), hasLength(1));
      expect(storage.values.keys.where(_secretKey), hasLength(1));

      storage.failWriteAfter = null;
      storage.failDeleteBefore = null;
      final restarted = RdpSchema6SecureSecretVault(storage: storage);
      await expectLater(
        restarted.save(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          secret: Uint8List.fromList([8]),
          isCurrent: () => false,
        ),
        throwsA(
          isA<RdpFailure>().having((value) => value.code, 'code', 'retired'),
        ),
      );
      expect(storage.values.keys.where(_candidateDebtKey), isEmpty);
      expect(storage.values.keys.where(_secretKey), isEmpty);
    },
  );

  test('first current write uncertainty is reconciled after restart', () async {
    final storage = _FaultStorage();
    var writeFailed = false;
    storage.failWriteAfter = (key, _) {
      if (!writeFailed && _secretKey(key)) {
        writeFailed = true;
        return true;
      }
      return false;
    };
    storage.failDeleteBefore = _secretKey;
    final vault = RdpSchema6SecureSecretVault(storage: storage);

    await expectLater(
      vault.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.targetPassword,
        secret: Uint8List.fromList([6, 7]),
        isCurrent: () => true,
      ),
      throwsA(
        isA<RdpFailure>().having(
          (value) => value.code,
          'code',
          'storage_failed',
        ),
      ),
    );
    expect(storage.values.keys.where(_candidateDebtKey), hasLength(1));
    expect(storage.values.keys.where(_secretKey), hasLength(1));
    expect(storage.values.keys.where(_currentKey), isEmpty);

    storage.failWriteAfter = null;
    storage.failDeleteBefore = null;
    final restarted = RdpSchema6SecureSecretVault(storage: storage);
    expect(
      await restarted.resolveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.targetPassword,
        isCurrent: () => true,
      ),
      isNull,
    );
    expect(storage.values, isEmpty);
  });

  test(
    'retirement after current-pointer write restores the prior publication',
    () async {
      final storage = _FaultStorage();
      final vault = RdpSchema6SecureSecretVault(storage: storage);
      await vault.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([1, 2]),
        isCurrent: () => true,
      );
      var current = true;
      storage.afterWrite = (key) {
        if (_currentKey(key)) current = false;
      };

      await expectLater(
        vault.saveCurrent(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          secret: Uint8List.fromList([3, 4]),
          isCurrent: () => current,
        ),
        throwsA(
          isA<RdpFailure>().having((value) => value.code, 'code', 'retired'),
        ),
      );

      storage.afterWrite = null;
      current = true;
      final retained = await vault.resolveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => current,
      );
      expect(retained?.bytes, [1, 2]);
      expect(storage.values.keys.where(_secretKey), hasLength(1));
      expect(storage.values.keys.where(_cleanupDebtKey), isEmpty);
    },
  );

  test(
    'retirement during pointer readback restores prior pointer and secret',
    () async {
      final storage = _FaultStorage();
      final vault = RdpSchema6SecureSecretVault(storage: storage);
      await vault.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([5, 6]),
        isCurrent: () => true,
      );
      var current = true;
      var pointerWritten = false;
      storage.afterWrite = (key) {
        if (_currentKey(key)) pointerWritten = true;
      };
      storage.afterRead = (key) {
        if (pointerWritten && _currentKey(key)) current = false;
      };

      await expectLater(
        vault.saveCurrent(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          secret: Uint8List.fromList([7, 8]),
          isCurrent: () => current,
        ),
        throwsA(
          isA<RdpFailure>().having((value) => value.code, 'code', 'retired'),
        ),
      );

      storage.afterWrite = null;
      storage.afterRead = null;
      current = true;
      final retained = await vault.resolveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => current,
      );
      expect(retained?.bytes, [5, 6]);
      expect(storage.values.keys.where(_secretKey), hasLength(1));
      expect(storage.values.keys.where(_cleanupDebtKey), isEmpty);
    },
  );

  test('failed prior cleanup rolls back and a retry rotates once', () async {
    final storage = _FaultStorage();
    final vault = RdpSchema6SecureSecretVault(storage: storage);
    await vault.saveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([1]),
      isCurrent: () => true,
    );
    final firstKey = storage.values.keys.singleWhere(_secretKey);
    var failed = false;
    storage.failDeleteBefore = (key) {
      if (key == firstKey && !failed) {
        failed = true;
        return true;
      }
      return false;
    };

    await expectLater(
      vault.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([2]),
        isCurrent: () => true,
      ),
      throwsA(
        isA<RdpFailure>().having(
          (value) => value.code,
          'code',
          'storage_failed',
        ),
      ),
    );
    expect(storage.values.keys.where(_secretKey), hasLength(1));
    expect(storage.values.keys.where(_cleanupDebtKey), isEmpty);

    storage.failDeleteBefore = null;
    await vault.saveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([3]),
      isCurrent: () => true,
    );
    final current = await vault.resolveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      isCurrent: () => true,
    );
    expect(current?.bytes, [3]);
    expect(storage.values.keys.where(_secretKey), hasLength(1));
  });

  test('cleanup debt survives unknown rollback and reconciles once', () async {
    final storage = _FaultStorage();
    final vault = RdpSchema6SecureSecretVault(storage: storage);
    final first = await vault.saveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([4]),
      isCurrent: () => true,
    );
    final firstKey = storage.values.keys.singleWhere(_secretKey);
    var deleteFailed = false;
    storage.failDeleteBefore = (key) {
      if (key == firstKey && !deleteFailed) {
        deleteFailed = true;
        return true;
      }
      return false;
    };
    storage.failWriteBefore = (key, value) =>
        deleteFailed &&
        _currentKey(key) &&
        value?.contains(first.value) == true;

    await expectLater(
      vault.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([9]),
        isCurrent: () => true,
      ),
      throwsA(
        isA<RdpFailure>().having(
          (value) => value.code,
          'code',
          'storage_failed',
        ),
      ),
    );
    expect(storage.values.keys.where(_cleanupDebtKey), hasLength(1));
    expect(storage.values.keys.where(_secretKey), hasLength(2));

    storage.failDeleteBefore = null;
    storage.failWriteBefore = null;
    final recovered = await vault.resolveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      isCurrent: () => true,
    );
    expect(recovered?.bytes, [9]);
    expect(storage.values.keys.where(_cleanupDebtKey), isEmpty);
    expect(storage.values.keys.where(_secretKey), hasLength(1));
  });

  test(
    'cleanup debt removes the uncommitted secret after uncertain rollback',
    () async {
      final storage = _FaultStorage();
      final vault = RdpSchema6SecureSecretVault(storage: storage);
      await vault.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([4]),
        isCurrent: () => true,
      );
      final firstKey = storage.values.keys.singleWhere(_secretKey);
      var deleteFailed = false;
      storage.failDeleteBefore = (key) {
        if (key == firstKey && !deleteFailed) {
          deleteFailed = true;
          return true;
        }
        return false;
      };
      var pointerWrites = 0, rollbackReadFailed = false;
      storage.afterWrite = (key) {
        if (_currentKey(key)) pointerWrites++;
      };
      storage.afterRead = (key) {
        if (_currentKey(key) && pointerWrites >= 2 && !rollbackReadFailed) {
          rollbackReadFailed = true;
          throw StateError('read');
        }
      };

      await expectLater(
        vault.saveCurrent(
          scope: scope(),
          kind: RdpSchema6SecretKind.gatewayPassword,
          secret: Uint8List.fromList([9]),
          isCurrent: () => true,
        ),
        throwsA(
          isA<RdpFailure>().having(
            (value) => value.code,
            'code',
            'storage_failed',
          ),
        ),
      );
      expect(storage.values.keys.where(_cleanupDebtKey), hasLength(1));
      expect(storage.values.keys.where(_secretKey), hasLength(2));

      storage.failDeleteBefore = null;
      storage.afterWrite = null;
      storage.afterRead = null;
      final recovered = await vault.resolveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );
      expect(recovered?.bytes, [4]);
      expect(storage.values.keys.where(_cleanupDebtKey), isEmpty);
      expect(storage.values.keys.where(_secretKey), hasLength(1));
    },
  );

  test(
    'published higher revision retires old pointer after process restart',
    () async {
      final storage = _FaultStorage();
      final first = RdpSchema6SecureSecretVault(storage: storage);
      await first.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([1, 2, 3]),
        isCurrent: () => true,
      );
      await first.ownCurrentForCleanup(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );
      await first.saveCurrent(
        scope: scope(2),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([8, 9]),
        isCurrent: () => true,
      );
      expect(storage.values.keys.where(_retirementKey), hasLength(1));
      expect(storage.values.keys.where(_currentKey), hasLength(2));
      expect(storage.values.keys.where(_secretKey), hasLength(2));

      final restarted = RdpSchema6SecureSecretVault(storage: storage);
      await restarted.reconcileRetired(
        namespaceDigest: scope().namespaceDigest,
        kind: RdpSchema6SecretKind.gatewayPassword,
        activeProfileRevisions: {scope().profileRef: 2},
        isCurrent: () => true,
      );

      expect(storage.values.keys.where(_retirementKey), isEmpty);
      expect(storage.values.keys.where(_currentKey), hasLength(1));
      expect(storage.values.keys.where(_secretKey), hasLength(1));
      final retained = await restarted.resolveCurrent(
        scope: scope(2),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );
      expect(retained?.bytes, [8, 9]);
    },
  );

  test(
    'same revision aborts retirement and preserves the current secret',
    () async {
      final storage = _FaultStorage();
      final first = RdpSchema6SecureSecretVault(storage: storage);
      await first.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([4, 5, 6]),
        isCurrent: () => true,
      );
      await first.ownCurrentForCleanup(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );

      final restarted = RdpSchema6SecureSecretVault(storage: storage);
      await restarted.reconcileRetired(
        namespaceDigest: scope().namespaceDigest,
        kind: RdpSchema6SecretKind.gatewayPassword,
        activeProfileRevisions: {scope().profileRef: 1},
        isCurrent: () => true,
      );

      final retained = await restarted.resolveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );
      expect(retained?.bytes, [4, 5, 6]);
      expect(storage.values.keys.where(_retirementKey), isEmpty);
      expect(storage.values.keys.where(_currentKey), hasLength(1));
      expect(storage.values.keys.where(_secretKey), hasLength(1));
    },
  );

  test(
    'profile deletion after restart retires exact old pointer and secret',
    () async {
      final storage = _FaultStorage();
      final first = RdpSchema6SecureSecretVault(storage: storage);
      await first.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([7, 8]),
        isCurrent: () => true,
      );
      await first.ownCurrentForCleanup(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );

      final restarted = RdpSchema6SecureSecretVault(storage: storage);
      await restarted.reconcileRetired(
        namespaceDigest: scope().namespaceDigest,
        kind: RdpSchema6SecretKind.gatewayPassword,
        activeProfileRevisions: const {},
        isCurrent: () => true,
      );

      expect(storage.values, isEmpty);
    },
  );

  test(
    'failed retirement deletion remains indexed and restart retries once',
    () async {
      final storage = _FaultStorage();
      final first = RdpSchema6SecureSecretVault(storage: storage);
      await first.saveCurrent(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        secret: Uint8List.fromList([9, 1]),
        isCurrent: () => true,
      );
      final cleanup = await first.ownCurrentForCleanup(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      );
      var failed = false;
      storage.failDeleteBefore = (key) {
        if (!failed && _secretKey(key)) {
          failed = true;
          return true;
        }
        return false;
      };

      await expectLater(
        cleanup!.delete(),
        throwsA(
          isA<RdpFailure>().having(
            (value) => value.code,
            'code',
            'storage_failed',
          ),
        ),
      );
      expect(storage.values.keys.where(_retirementKey), hasLength(1));
      expect(storage.values.keys.where(_currentKey), isEmpty);
      expect(storage.values.keys.where(_secretKey), hasLength(1));

      storage.failDeleteBefore = null;
      final restarted = RdpSchema6SecureSecretVault(storage: storage);
      await restarted.reconcileRetired(
        namespaceDigest: scope().namespaceDigest,
        kind: RdpSchema6SecretKind.gatewayPassword,
        activeProfileRevisions: const {},
        isCurrent: () => true,
      );

      expect(storage.values, isEmpty);
    },
  );

  test('retirement inventory is exact and bounded before Core mutation', () async {
    final storage = _FaultStorage();
    final vault = RdpSchema6SecureSecretVault(storage: storage);
    await vault.saveCurrent(
      scope: scope(),
      kind: RdpSchema6SecretKind.gatewayPassword,
      secret: Uint8List.fromList([2]),
      isCurrent: () => true,
    );
    final entries = List.generate(32, (index) {
      final value = index.toRadixString(16).padLeft(64, '0');
      return {
        'profileRef': value,
        'profileRevision': 1,
        'reference': index.toRadixString(16).padLeft(32, '0'),
      };
    });
    storage.values['rdp_schema6_secret_retirements_v1_${scope().namespaceDigest}_gatewayPassword'] =
        '{"schemaVersion":1,"namespaceDigest":"${scope().namespaceDigest}",'
        '"kind":"gatewayPassword","entries":${jsonEncode(entries)}}';

    await expectLater(
      vault.ownCurrentForCleanup(
        scope: scope(),
        kind: RdpSchema6SecretKind.gatewayPassword,
        isCurrent: () => true,
      ),
      throwsA(
        isA<RdpFailure>().having(
          (value) => value.code,
          'code',
          'storage_failed',
        ),
      ),
    );
    expect(storage.values.keys.where(_currentKey), hasLength(1));
    expect(storage.values.keys.where(_secretKey), hasLength(1));
  });
}
