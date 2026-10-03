import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import 'rdp_models.dart';
import 'rdp_schema6_models.dart';

enum RdpSchema6SecretKind { targetPassword, gatewayPassword }

final class RdpSchema6SecretScope {
  RdpSchema6SecretScope({
    required this.namespaceDigest,
    required this.profileRef,
    required this.profileRevision,
  }) {
    final digest = RegExp(r'^[0-9a-f]{64}$');
    if (!digest.hasMatch(namespaceDigest) ||
        !digest.hasMatch(profileRef) ||
        profileRevision < 1 ||
        profileRevision > 9007199254740991) {
      throw const RdpFailure('invalid_authority');
    }
  }

  final String namespaceDigest, profileRef;
  final int profileRevision;
}

abstract interface class RdpSchema6SecretVault {
  Future<RdpDeviceSecretReference> save({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  });

  Future<RdpOwnedSecretBuffer> resolve({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required RdpDeviceSecretReference reference,
    required bool Function() isCurrent,
  });

  Future<void> delete({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required RdpDeviceSecretReference reference,
    required bool Function() isCurrent,
  });
}

abstract interface class RdpSchema6CurrentSecretVault
    implements RdpSchema6SecretVault {
  Future<RdpSchema6OwnedSecretCleanup> saveOwned({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  });

  Future<RdpSchema6OwnedSecretCleanup?> ownCurrentForCleanup({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  });

  Future<RdpDeviceSecretReference> saveCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  });

  Future<RdpOwnedSecretBuffer?> resolveCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  });

  Future<void> deleteCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  });

  /// Reconciles deletion-only retirement intents against one fresh, complete
  /// Core profile inventory. Equal revisions cancel an uncommitted intent and
  /// preserve its secret; a higher revision or an absent profile confirms that
  /// the captured old revision is no longer authoritative and may be erased.
  Future<void> reconcileRetired({
    required String namespaceDigest,
    required RdpSchema6SecretKind kind,
    required Map<String, int> activeProfileRevisions,
    required bool Function() isCurrent,
  });
}

/// A deletion-only capability for one exact secret created or observed while
/// its authority was current. It cannot resolve, replace, or republish data.
final class RdpSchema6OwnedSecretCleanup {
  RdpSchema6OwnedSecretCleanup._(this.reference, this._delete);

  final RdpDeviceSecretReference reference;
  final Future<void> Function() _delete;
  bool _deleted = false;

  Future<void> delete() async {
    if (_deleted) return;
    await _delete();
    _deleted = true;
  }

  @override
  String toString() => 'RdpSchema6OwnedSecretCleanup(redacted)';
}

final class _RdpSchema6SecretRotationDebt {
  const _RdpSchema6SecretRotationDebt(this.previous, this.next);

  final RdpDeviceSecretReference previous, next;
}

final class _RdpSchema6SecretCandidateDebt {
  const _RdpSchema6SecretCandidateDebt(this.reference, this.purpose);

  final RdpDeviceSecretReference reference;
  final _RdpSchema6SecretPurpose purpose;
}

final class _RdpSchema6SecretRetirement {
  const _RdpSchema6SecretRetirement({
    required this.profileRef,
    required this.profileRevision,
    required this.reference,
  });

  final String profileRef;
  final int profileRevision;
  final RdpDeviceSecretReference reference;
}

enum _RdpSchema6SecretPurpose { candidate, saved, temporary, current }

final class RdpSchema6SecureSecretVault
    implements RdpSchema6CurrentSecretVault {
  RdpSchema6SecureSecretVault({FlutterSecureStorage? storage, Random? random})
    : _storage = storage ?? const FlutterSecureStorage(),
      _random = random ?? Random.secure();

  final FlutterSecureStorage _storage;
  final Random _random;

  String _key(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference reference,
  ) =>
      'rdp_schema6_secret_v1_${scope.namespaceDigest}_${scope.profileRef}_'
      '${kind.name}_${reference.value}';

  String _currentKey(RdpSchema6SecretScope scope, RdpSchema6SecretKind kind) =>
      'rdp_schema6_current_secret_v1_${scope.namespaceDigest}_'
      '${scope.profileRef}_${scope.profileRevision}_${kind.name}';

  String _cleanupDebtKey(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
  ) =>
      'rdp_schema6_secret_cleanup_v1_${scope.namespaceDigest}_'
      '${scope.profileRef}_${scope.profileRevision}_${kind.name}';

  String _candidateDebtKey(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
  ) =>
      'rdp_schema6_secret_candidate_cleanup_v1_${scope.namespaceDigest}_'
      '${scope.profileRef}_${scope.profileRevision}_${kind.name}';

  String _retirementKey(String namespaceDigest, RdpSchema6SecretKind kind) =>
      'rdp_schema6_secret_retirements_v1_${namespaceDigest}_${kind.name}';

  void Function() _guard(bool Function() isCurrent) {
    var retired = false;
    return () {
      try {
        if (!retired && isCurrent()) return;
      } catch (_) {}
      retired = true;
      throw const RdpFailure('retired');
    };
  }

  @override
  Future<RdpDeviceSecretReference> save({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  }) {
    final owned = Uint8List.fromList(secret);
    return ConfigurationWrites.run(() async {
      try {
        return await _saveWithIntent(
          scope: scope,
          kind: kind,
          owned: owned,
          purpose: _RdpSchema6SecretPurpose.saved,
          isCurrent: isCurrent,
        );
      } finally {
        owned.fillRange(0, owned.length, 0);
        secret.fillRange(0, secret.length, 0);
      }
    });
  }

  Future<RdpDeviceSecretReference> _saveWithIntent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List owned,
    required _RdpSchema6SecretPurpose purpose,
    required bool Function() isCurrent,
  }) async {
    final check = _guard(isCurrent);
    String? secretKey;
    final debtKey = _candidateDebtKey(scope, kind);
    var debtWritten = false;
    try {
      await _reconcileCandidateDebt(scope, kind);
      check();
      _validateSecret(owned);
      final reference = RdpDeviceSecretReference(_randomHex(16));
      final key = _key(scope, kind, reference);
      final value = jsonEncode({
        'schemaVersion': 1,
        'namespaceDigest': scope.namespaceDigest,
        'profileRef': scope.profileRef,
        'profileRevision': scope.profileRevision,
        'kind': kind.name,
        'reference': reference.value,
        'secret': base64Encode(owned),
      });
      check();
      if (await _storage.read(key: key) != null ||
          await _storage.read(key: debtKey) != null) {
        throw const RdpFailure('storage_failed');
      }
      await _writeKeyConfirmed(
        debtKey,
        _candidateDebtValue(
          scope,
          kind,
          reference,
          _RdpSchema6SecretPurpose.candidate,
        ),
      );
      debtWritten = true;
      secretKey = key;
      check();
      await _storage.write(key: key, value: value);
      check();
      if (await _storage.read(key: key) != value) {
        throw const RdpFailure('storage_failed');
      }
      await _writeKeyConfirmed(
        debtKey,
        _candidateDebtValue(scope, kind, reference, purpose),
      );
      check();
      return reference;
    } catch (error, stack) {
      if (secretKey case final key?) {
        try {
          await _deleteKeyConfirmed(key);
          if (debtWritten) await _deleteKeyConfirmed(debtKey);
        } catch (_) {
          throw const RdpFailure('storage_failed');
        }
      } else if (debtWritten) {
        try {
          await _deleteKeyConfirmed(debtKey);
        } catch (_) {
          throw const RdpFailure('storage_failed');
        }
      }
      if (error is RdpFailure) Error.throwWithStackTrace(error, stack);
      throw const RdpFailure('storage_failed');
    }
  }

  @override
  Future<RdpSchema6OwnedSecretCleanup> saveOwned({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  }) {
    final owned = Uint8List.fromList(secret);
    return ConfigurationWrites.run(() async {
      try {
        final reference = await _saveWithIntent(
          scope: scope,
          kind: kind,
          owned: owned,
          purpose: _RdpSchema6SecretPurpose.temporary,
          isCurrent: isCurrent,
        );
        return _cleanup(scope, kind, reference);
      } finally {
        owned.fillRange(0, owned.length, 0);
        secret.fillRange(0, secret.length, 0);
      }
    });
  }

  @override
  Future<RdpSchema6OwnedSecretCleanup?> ownCurrentForCleanup({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    final check = _guard(isCurrent);
    await _reconcileCandidateDebt(scope, kind);
    check();
    await _reconcileCleanupDebt(scope, kind);
    check();
    final reference = await _readCurrentReference(scope, kind, check);
    check();
    if (reference == null) return null;
    final retirements = await _readRetirements(scope.namespaceDigest, kind);
    final matching = retirements.where(
      (item) => item.profileRef == scope.profileRef,
    );
    if (matching.isNotEmpty) {
      final existing = matching.single;
      if (existing.profileRevision != scope.profileRevision ||
          existing.reference != reference) {
        throw const RdpFailure('storage_failed');
      }
    } else {
      if (retirements.length >= 32) {
        throw const RdpFailure('storage_failed');
      }
      await _writeRetirements(scope.namespaceDigest, kind, [
        ...retirements,
        _RdpSchema6SecretRetirement(
          profileRef: scope.profileRef,
          profileRevision: scope.profileRevision,
          reference: reference,
        ),
      ]);
    }
    check();
    return _retirementCleanup(scope, kind, reference);
  });

  RdpSchema6OwnedSecretCleanup _retirementCleanup(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference reference,
  ) => RdpSchema6OwnedSecretCleanup._(reference, () async {
    try {
      await ConfigurationWrites.run(() async {
        final retirements = await _readRetirements(scope.namespaceDigest, kind);
        final matches = retirements.where(
          (item) =>
              item.profileRef == scope.profileRef &&
              item.profileRevision == scope.profileRevision &&
              item.reference == reference,
        );
        if (matches.isEmpty) {
          final pointer = await _storage.read(key: _currentKey(scope, kind));
          final secret = await _storage.read(key: _key(scope, kind, reference));
          if (pointer == null && secret == null) return;
          throw const RdpFailure('storage_failed');
        }
        if (matches.length != 1) throw const RdpFailure('invalid_record');
        await _deleteRetiredRecord(scope, kind, reference);
        await _writeRetirements(
          scope.namespaceDigest,
          kind,
          retirements.where((item) => item != matches.single).toList(),
        );
      });
    } on RdpFailure {
      rethrow;
    } catch (_) {
      throw const RdpFailure('storage_failed');
    }
  });

  RdpSchema6OwnedSecretCleanup _cleanup(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference reference, {
    bool current = false,
  }) {
    final secretKey = _key(scope, kind, reference);
    final currentKey = _currentKey(scope, kind);
    return RdpSchema6OwnedSecretCleanup._(reference, () async {
      try {
        await ConfigurationWrites.run(() async {
          if (current) {
            await _reconcileCleanupDebt(scope, kind);
            final raw = await _storage.read(key: currentKey);
            if (raw != null) {
              final currentReference = _decodeCurrentReference(
                raw,
                scope,
                kind,
              );
              if (currentReference == reference) {
                await _storage.delete(key: currentKey);
                if (await _storage.read(key: currentKey) != null) {
                  throw const RdpFailure('storage_failed');
                }
              }
            }
          }
          await _reconcileCandidateDebt(
            scope,
            kind,
            reference: reference,
            deleteReference: true,
          );
          await _deleteKeyConfirmed(secretKey);
        });
      } on RdpFailure {
        rethrow;
      } catch (_) {
        throw const RdpFailure('storage_failed');
      }
    });
  }

  @override
  Future<RdpOwnedSecretBuffer> resolve({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required RdpDeviceSecretReference reference,
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    final check = _guard(isCurrent);
    Uint8List? decoded;
    try {
      await _reconcileCandidateDebt(scope, kind, reference: reference);
      check();
      final raw = await _storage.read(key: _key(scope, kind, reference));
      check();
      if (raw == null || utf8.encode(raw).length > 8192) {
        throw const RdpFailure('secret_unavailable');
      }
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 7 ||
          value['schemaVersion'] != 1 ||
          value['namespaceDigest'] != scope.namespaceDigest ||
          value['profileRef'] != scope.profileRef ||
          value['profileRevision'] != scope.profileRevision ||
          value['kind'] != kind.name ||
          value['reference'] != reference.value ||
          value['secret'] is! String) {
        throw const RdpFailure('invalid_record');
      }
      try {
        decoded = base64Decode(value['secret'] as String);
      } catch (_) {
        throw const RdpFailure('invalid_record');
      }
      _validateSecret(decoded);
      check();
      return RdpOwnedSecretBuffer(decoded);
    } on RdpFailure {
      rethrow;
    } catch (_) {
      check();
      throw const RdpFailure('storage_failed');
    } finally {
      decoded?.fillRange(0, decoded.length, 0);
    }
  });

  @override
  Future<void> delete({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required RdpDeviceSecretReference reference,
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    final check = _guard(isCurrent);
    try {
      await _reconcileCandidateDebt(
        scope,
        kind,
        reference: reference,
        deleteReference: true,
      );
      check();
      await _deleteKeyConfirmed(_key(scope, kind, reference));
      check();
    } on RdpFailure {
      rethrow;
    } catch (_) {
      check();
      throw const RdpFailure('storage_failed');
    }
  });

  @override
  Future<RdpDeviceSecretReference> saveCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required Uint8List secret,
    required bool Function() isCurrent,
  }) {
    final owned = Uint8List.fromList(secret);
    return ConfigurationWrites.run(() async {
      final check = _guard(isCurrent);
      try {
        await _reconcileCandidateDebt(scope, kind);
        check();
        await _reconcileCleanupDebt(scope, kind);
        check();
        final previous = await _readCurrentReference(scope, kind, check);
        final next = await _saveWithIntent(
          scope: scope,
          kind: kind,
          owned: owned,
          purpose: _RdpSchema6SecretPurpose.current,
          isCurrent: isCurrent,
        );
        final nextCleanup = _cleanup(scope, kind, next);
        final currentKey = _currentKey(scope, kind);
        final currentValue = _currentValue(scope, kind, next);
        final previousCleanup = previous == null || previous == next
            ? null
            : _cleanup(scope, kind, previous);
        var previousDeleted = false;
        try {
          check();
          if (previousCleanup != null) {
            final debtKey = _cleanupDebtKey(scope, kind);
            final debtValue = _cleanupDebtValue(scope, kind, previous!, next);
            if (await _storage.read(key: debtKey) != null) {
              throw const RdpFailure('storage_failed');
            }
            await _storage.write(key: debtKey, value: debtValue);
            check();
            if (await _storage.read(key: debtKey) != debtValue) {
              throw const RdpFailure('storage_failed');
            }
          }
          check();
          await _storage.write(key: currentKey, value: currentValue);
          check();
          if (await _storage.read(key: currentKey) != currentValue) {
            throw const RdpFailure('storage_failed');
          }
          check();
          if (previousCleanup != null) {
            await previousCleanup.delete();
            previousDeleted = true;
            await _deleteKeyConfirmed(_cleanupDebtKey(scope, kind));
            check();
          }
          return next;
        } catch (error, stack) {
          try {
            await _rollbackCurrentPublication(
              scope,
              kind,
              next,
              previousDeleted ? null : previous,
            );
            await nextCleanup.delete();
            await _reconcileCleanupDebt(scope, kind);
          } catch (_) {
            throw const RdpFailure('storage_failed');
          }
          if (error is RdpFailure) {
            Error.throwWithStackTrace(error, stack);
          }
          throw const RdpFailure('storage_failed');
        }
      } finally {
        owned.fillRange(0, owned.length, 0);
        secret.fillRange(0, secret.length, 0);
      }
    });
  }

  @override
  Future<RdpOwnedSecretBuffer?> resolveCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    final check = _guard(isCurrent);
    await _reconcileCandidateDebt(scope, kind);
    check();
    await _reconcileCleanupDebt(scope, kind);
    check();
    final reference = await _readCurrentReference(scope, kind, check);
    if (reference == null) return null;
    return resolve(
      scope: scope,
      kind: kind,
      reference: reference,
      isCurrent: isCurrent,
    );
  });

  @override
  Future<void> deleteCurrent({
    required RdpSchema6SecretScope scope,
    required RdpSchema6SecretKind kind,
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    final check = _guard(isCurrent);
    await _reconcileCandidateDebt(scope, kind);
    check();
    await _reconcileCleanupDebt(scope, kind);
    check();
    final reference = await _readCurrentReference(scope, kind, check);
    if (reference == null) return;
    check();
    await _cleanup(scope, kind, reference, current: true).delete();
  });

  @override
  Future<void> reconcileRetired({
    required String namespaceDigest,
    required RdpSchema6SecretKind kind,
    required Map<String, int> activeProfileRevisions,
    required bool Function() isCurrent,
  }) => ConfigurationWrites.run(() async {
    final check = _guard(isCurrent);
    _validateInventory(namespaceDigest, activeProfileRevisions);
    check();
    var retirements = await _readRetirements(namespaceDigest, kind);
    check();
    for (final retirement in List<_RdpSchema6SecretRetirement>.from(
      retirements,
    )) {
      check();
      final activeRevision = activeProfileRevisions[retirement.profileRef];
      if (activeRevision != null &&
          activeRevision < retirement.profileRevision) {
        throw const RdpFailure('invalid_record');
      }
      final scope = RdpSchema6SecretScope(
        namespaceDigest: namespaceDigest,
        profileRef: retirement.profileRef,
        profileRevision: retirement.profileRevision,
      );
      if (activeRevision == retirement.profileRevision) {
        await _confirmRetainedRecord(scope, kind, retirement.reference);
      } else {
        await _deleteRetiredRecord(scope, kind, retirement.reference);
      }
      check();
      retirements = retirements
          .where((item) => item != retirement)
          .toList(growable: false);
      await _writeRetirements(namespaceDigest, kind, retirements);
      check();
    }
  });

  Future<void> _confirmRetainedRecord(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference reference,
  ) async {
    final pointerRaw = await _storage.read(key: _currentKey(scope, kind));
    if (pointerRaw == null ||
        _decodeCurrentReference(pointerRaw, scope, kind) != reference ||
        await _storage.read(key: _key(scope, kind, reference)) == null) {
      throw const RdpFailure('invalid_record');
    }
  }

  Future<void> _deleteRetiredRecord(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference reference,
  ) async {
    await _reconcileCandidateDebt(
      scope,
      kind,
      reference: reference,
      deleteReference: true,
    );
    await _reconcileCleanupDebt(scope, kind);
    final pointerKey = _currentKey(scope, kind);
    final pointerRaw = await _storage.read(key: pointerKey);
    if (pointerRaw != null) {
      final pointer = _decodeCurrentReference(pointerRaw, scope, kind);
      if (pointer == reference) await _deleteKeyConfirmed(pointerKey);
    }
    await _deleteKeyConfirmed(_key(scope, kind, reference));
  }

  String _currentValue(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference reference,
  ) => jsonEncode({
    'schemaVersion': 1,
    'namespaceDigest': scope.namespaceDigest,
    'profileRef': scope.profileRef,
    'profileRevision': scope.profileRevision,
    'kind': kind.name,
    'reference': reference.value,
  });

  String _cleanupDebtValue(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference previous,
    RdpDeviceSecretReference next,
  ) => jsonEncode({
    'schemaVersion': 1,
    'namespaceDigest': scope.namespaceDigest,
    'profileRef': scope.profileRef,
    'profileRevision': scope.profileRevision,
    'kind': kind.name,
    'previousReference': previous.value,
    'nextReference': next.value,
  });

  String _candidateDebtValue(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference reference,
    _RdpSchema6SecretPurpose purpose,
  ) => jsonEncode({
    'schemaVersion': 1,
    'namespaceDigest': scope.namespaceDigest,
    'profileRef': scope.profileRef,
    'profileRevision': scope.profileRevision,
    'kind': kind.name,
    'candidateReference': reference.value,
    'purpose': purpose.name,
  });

  String _retirementValue(
    String namespaceDigest,
    RdpSchema6SecretKind kind,
    List<_RdpSchema6SecretRetirement> retirements,
  ) {
    final ordered = List<_RdpSchema6SecretRetirement>.from(retirements)
      ..sort((left, right) => left.profileRef.compareTo(right.profileRef));
    return jsonEncode({
      'schemaVersion': 1,
      'namespaceDigest': namespaceDigest,
      'kind': kind.name,
      'entries': ordered
          .map(
            (item) => {
              'profileRef': item.profileRef,
              'profileRevision': item.profileRevision,
              'reference': item.reference.value,
            },
          )
          .toList(growable: false),
    });
  }

  Future<List<_RdpSchema6SecretRetirement>> _readRetirements(
    String namespaceDigest,
    RdpSchema6SecretKind kind,
  ) async {
    final raw = await _storage.read(key: _retirementKey(namespaceDigest, kind));
    if (raw == null) return const [];
    if (utf8.encode(raw).length > 16384) {
      throw const RdpFailure('invalid_record');
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 4 ||
          value['schemaVersion'] != 1 ||
          value['namespaceDigest'] != namespaceDigest ||
          value['kind'] != kind.name ||
          value['entries'] is! List) {
        throw const RdpFailure('invalid_record');
      }
      final entries = value['entries'] as List;
      if (entries.isEmpty || entries.length > 32) {
        throw const RdpFailure('invalid_record');
      }
      final result = <_RdpSchema6SecretRetirement>[];
      String? previous;
      for (final rawEntry in entries) {
        if (rawEntry is! Map ||
            rawEntry.length != 3 ||
            rawEntry['profileRef'] is! String ||
            rawEntry['profileRevision'] is! int ||
            rawEntry['reference'] is! String) {
          throw const RdpFailure('invalid_record');
        }
        final profileRef = rawEntry['profileRef'] as String;
        final revision = rawEntry['profileRevision'] as int;
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(profileRef) ||
            revision < 1 ||
            revision > 9007199254740991 ||
            previous != null && previous.compareTo(profileRef) >= 0) {
          throw const RdpFailure('invalid_record');
        }
        result.add(
          _RdpSchema6SecretRetirement(
            profileRef: profileRef,
            profileRevision: revision,
            reference: RdpDeviceSecretReference(
              rawEntry['reference'] as String,
            ),
          ),
        );
        previous = profileRef;
      }
      return result;
    } on RdpFailure {
      rethrow;
    } catch (_) {
      throw const RdpFailure('invalid_record');
    }
  }

  Future<void> _writeRetirements(
    String namespaceDigest,
    RdpSchema6SecretKind kind,
    List<_RdpSchema6SecretRetirement> retirements,
  ) async {
    final key = _retirementKey(namespaceDigest, kind);
    if (retirements.isEmpty) {
      await _deleteKeyConfirmed(key);
      return;
    }
    if (retirements.length > 32) throw const RdpFailure('storage_failed');
    await _writeKeyConfirmed(
      key,
      _retirementValue(namespaceDigest, kind, retirements),
    );
  }

  void _validateInventory(
    String namespaceDigest,
    Map<String, int> activeProfileRevisions,
  ) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(namespaceDigest) ||
        activeProfileRevisions.length > 32) {
      throw const RdpFailure('invalid_record');
    }
    for (final entry in activeProfileRevisions.entries) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.key) ||
          entry.value < 1 ||
          entry.value > 9007199254740991) {
        throw const RdpFailure('invalid_record');
      }
    }
  }

  Future<void> _deleteKeyConfirmed(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    try {
      if (await _storage.read(key: key) != null) {
        throw const RdpFailure('storage_failed');
      }
    } on RdpFailure {
      rethrow;
    } catch (_) {
      throw const RdpFailure('storage_failed');
    }
  }

  Future<void> _writeKeyConfirmed(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {}
    try {
      if (await _storage.read(key: key) != value) {
        throw const RdpFailure('storage_failed');
      }
    } on RdpFailure {
      rethrow;
    } catch (_) {
      throw const RdpFailure('storage_failed');
    }
  }

  Future<void> _rollbackCurrentPublication(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    RdpDeviceSecretReference next,
    RdpDeviceSecretReference? previous,
  ) async {
    final key = _currentKey(scope, kind);
    final raw = await _storage.read(key: key);
    final current = raw == null
        ? null
        : _decodeCurrentReference(raw, scope, kind);
    if (current == next) {
      if (previous == null) {
        await _deleteKeyConfirmed(key);
      } else {
        await _writeKeyConfirmed(key, _currentValue(scope, kind, previous));
      }
    }
    final observedRaw = await _storage.read(key: key);
    final observed = observedRaw == null
        ? null
        : _decodeCurrentReference(observedRaw, scope, kind);
    if (observed == next) throw const RdpFailure('storage_failed');
  }

  Future<void> _reconcileCleanupDebt(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
  ) async {
    final debtKey = _cleanupDebtKey(scope, kind);
    final raw = await _storage.read(key: debtKey);
    if (raw == null) return;
    final debt = _decodeCleanupDebt(raw, scope, kind);
    final currentRaw = await _storage.read(key: _currentKey(scope, kind));
    final current = currentRaw == null
        ? null
        : _decodeCurrentReference(currentRaw, scope, kind);
    if (current != debt.previous) {
      await _deleteKeyConfirmed(_key(scope, kind, debt.previous));
    }
    if (current != debt.next) {
      await _deleteKeyConfirmed(_key(scope, kind, debt.next));
    }
    await _deleteKeyConfirmed(debtKey);
  }

  Future<void> _reconcileCandidateDebt(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind, {
    RdpDeviceSecretReference? reference,
    bool deleteReference = false,
  }) async {
    final debtKey = _candidateDebtKey(scope, kind);
    final raw = await _storage.read(key: debtKey);
    if (raw == null) return;
    final debt = _decodeCandidateDebt(raw, scope, kind);
    if (reference != null && reference != debt.reference) return;
    final currentRaw = await _storage.read(key: _currentKey(scope, kind));
    final current = currentRaw == null
        ? null
        : _decodeCurrentReference(currentRaw, scope, kind);
    if (current == debt.reference) {
      await _deleteKeyConfirmed(debtKey);
      return;
    }
    if (reference == debt.reference) {
      if (deleteReference) {
        await _deleteKeyConfirmed(_key(scope, kind, debt.reference));
        await _deleteKeyConfirmed(debtKey);
        return;
      }
      if (debt.purpose == _RdpSchema6SecretPurpose.saved) {
        await _deleteKeyConfirmed(debtKey);
        return;
      }
      if (debt.purpose == _RdpSchema6SecretPurpose.temporary) return;
    }
    if (debt.purpose == _RdpSchema6SecretPurpose.saved) {
      throw const RdpFailure('storage_failed');
    }
    await _deleteKeyConfirmed(_key(scope, kind, debt.reference));
    await _deleteKeyConfirmed(debtKey);
  }

  _RdpSchema6SecretCandidateDebt _decodeCandidateDebt(
    String raw,
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
  ) {
    if (utf8.encode(raw).length > 2048) {
      throw const RdpFailure('invalid_record');
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 7 ||
          value['schemaVersion'] != 1 ||
          value['namespaceDigest'] != scope.namespaceDigest ||
          value['profileRef'] != scope.profileRef ||
          value['profileRevision'] != scope.profileRevision ||
          value['kind'] != kind.name ||
          value['candidateReference'] is! String ||
          value['purpose'] is! String) {
        throw const RdpFailure('invalid_record');
      }
      final purpose = _RdpSchema6SecretPurpose.values.where(
        (item) => item.name == value['purpose'],
      );
      if (purpose.length != 1) throw const RdpFailure('invalid_record');
      return _RdpSchema6SecretCandidateDebt(
        RdpDeviceSecretReference(value['candidateReference'] as String),
        purpose.single,
      );
    } on RdpFailure {
      rethrow;
    } catch (_) {
      throw const RdpFailure('invalid_record');
    }
  }

  _RdpSchema6SecretRotationDebt _decodeCleanupDebt(
    String raw,
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
  ) {
    if (utf8.encode(raw).length > 2048) {
      throw const RdpFailure('invalid_record');
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 7 ||
          value['schemaVersion'] != 1 ||
          value['namespaceDigest'] != scope.namespaceDigest ||
          value['profileRef'] != scope.profileRef ||
          value['profileRevision'] != scope.profileRevision ||
          value['kind'] != kind.name ||
          value['previousReference'] is! String ||
          value['nextReference'] is! String) {
        throw const RdpFailure('invalid_record');
      }
      final previous = RdpDeviceSecretReference(
        value['previousReference'] as String,
      );
      final next = RdpDeviceSecretReference(value['nextReference'] as String);
      if (previous == next) throw const RdpFailure('invalid_record');
      return _RdpSchema6SecretRotationDebt(previous, next);
    } on RdpFailure {
      rethrow;
    } catch (_) {
      throw const RdpFailure('invalid_record');
    }
  }

  Future<RdpDeviceSecretReference?> _readCurrentReference(
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
    void Function() check,
  ) async {
    check();
    final raw = await _storage.read(key: _currentKey(scope, kind));
    check();
    if (raw == null) return null;
    if (utf8.encode(raw).length > 2048) {
      throw const RdpFailure('invalid_record');
    }
    return _decodeCurrentReference(raw, scope, kind);
  }

  RdpDeviceSecretReference _decodeCurrentReference(
    String raw,
    RdpSchema6SecretScope scope,
    RdpSchema6SecretKind kind,
  ) {
    if (utf8.encode(raw).length > 2048) {
      throw const RdpFailure('invalid_record');
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 6 ||
          value['schemaVersion'] != 1 ||
          value['namespaceDigest'] != scope.namespaceDigest ||
          value['profileRef'] != scope.profileRef ||
          value['profileRevision'] != scope.profileRevision ||
          value['kind'] != kind.name ||
          value['reference'] is! String) {
        throw const RdpFailure('invalid_record');
      }
      return RdpDeviceSecretReference(value['reference'] as String);
    } on RdpFailure {
      rethrow;
    } catch (_) {
      throw const RdpFailure('invalid_record');
    }
  }

  String _randomHex(int count) => List<int>.generate(
    count,
    (_) => _random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

void _validateSecret(Uint8List value) {
  if (value.isEmpty || value.length > 1024 || value.contains(0)) {
    throw const RdpFailure('invalid_request');
  }
}
