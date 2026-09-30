import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../data/remote_profiles.dart';
import '../data/remote_security_namespace.dart';
import 'vnc_models.dart';

typedef VncProfileValidator = Future<void> Function(
  RemoteProfile profile,
  void Function() check,
);

final class VncSecurityNamespace {
  VncSecurityNamespace._(this.digest, {required this.allowsLegacyLocal});

  factory VncSecurityNamespace.local() {
    final value = RemoteSecurityNamespace.local();
    return VncSecurityNamespace._(
      value.digest,
      allowsLegacyLocal: value.allowsLegacyLocal,
    );
  }

  factory VncSecurityNamespace.coreManaged({
    required String endpoint,
    required String coreId,
    required String homeId,
    required String accountId,
    required String sessionFamilyId,
  }) {
    try {
      final value = RemoteSecurityNamespace.coreManaged(
        endpoint: endpoint,
        coreId: coreId,
        homeId: homeId,
        accountId: accountId,
        sessionFamilyId: sessionFamilyId,
      );
      return VncSecurityNamespace._(
        value.digest,
        allowsLegacyLocal: value.allowsLegacyLocal,
      );
    } on FormatException {
      throw const VncFailure('invalid_namespace');
    }
  }

  final String digest;
  final bool allowsLegacyLocal;
}

abstract interface class VncTrustStore {
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<VncCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<void> trust(
    RemoteProfile profile,
    VncCertificatePin value, {
    required bool Function() isCurrent,
  });
}

/// Stores only a certificate binding. VNC passwords are never persisted.
class VncSecurityStore implements VncTrustStore {
  VncSecurityStore({
    FlutterSecureStorage? storage,
    RemoteProfilesStore? profiles,
    VncSecurityNamespace? namespace,
    this.profileValidator,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _profiles = profiles ?? RemoteProfilesStore(),
       _namespace = namespace ?? VncSecurityNamespace.local();

  final FlutterSecureStorage _storage;
  final RemoteProfilesStore _profiles;
  final VncSecurityNamespace _namespace;
  final VncProfileValidator? profileValidator;

  String reference(RemoteProfile profile) =>
      sha256.convert(utf8.encode(jsonEncode(profile.toJson()))).toString();
  String _key(String target) =>
      'vnc_certificate_v2_${_namespace.digest}_$target';
  String _legacyKey(String target) => 'vnc_certificate_v1_$target';

  void Function() _guard(bool Function() current) {
    var retired = false;
    return () {
      try {
        if (!retired && current()) return;
      } catch (_) {}
      retired = true;
      throw const VncFailure('retired');
    };
  }

  Future<void> _profile(RemoteProfile profile, void Function() check) async {
    if (profile.protocol != RemoteProtocol.vnc) {
      throw const VncFailure('profile_changed');
    }
    if (profileValidator case final validator?) {
      await validator(profile, check);
      check();
      return;
    }
    check();
    final snapshot = await _profiles.read(
      isCurrent: () {
        check();
        return true;
      },
    );
    check();
    if (!snapshot.profiles.any(
      (value) => reference(value) == reference(profile),
    )) {
      throw const VncFailure('profile_changed');
    }
  }

  Future<T> _run<T>(
    RemoteProfile profile,
    bool Function() current,
    Future<T> Function(void Function()) action,
  ) {
    final check = _guard(current);
    return ConfigurationWrites.run(() async {
      try {
        await _profile(profile, check);
        check();
        final result = await action(check);
        check();
        await _profile(profile, check);
        check();
        return result;
      } on VncFailure {
        rethrow;
      } on RemoteProfilesFailure catch (error) {
        throw VncFailure(
          error.code == 'retired' ? 'retired' : 'profile_changed',
        );
      } catch (_) {
        check();
        throw const VncFailure('storage_failed');
      }
    });
  }

  Future<Map<String, dynamic>?> _read(
    RemoteProfile profile,
    void Function() check,
  ) async {
    final target = reference(profile);
    check();
    var raw = await _storage.read(key: _key(target));
    check();
    var legacy = false;
    if (raw == null && _namespace.allowsLegacyLocal) {
      raw = await _storage.read(key: _legacyKey(target));
      check();
      legacy = raw != null;
    }
    if (raw == null) return null;
    if (utf8.encode(raw).length > 512) {
      throw const VncFailure('invalid_record');
    }
    final value = jsonDecode(raw);
    if (value is! Map ||
        value.length != (legacy ? 4 : 5) ||
        value['version'] != (legacy ? 1 : 2) ||
        value['version'] is! int ||
        value['target'] != target ||
        (!legacy && value['namespace'] != _namespace.digest) ||
        value['algorithm'] is! String ||
        value['fingerprint'] is! String) {
      throw const VncFailure('invalid_record');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<void> _write(
    RemoteProfile profile,
    VncCertificatePin value,
    void Function() check,
  ) async {
    final target = reference(profile);
    final key = _key(target);
    final raw = jsonEncode({
      'version': 2,
      'namespace': _namespace.digest,
      'target': target,
      'algorithm': value.algorithm,
      'fingerprint': value.fingerprint,
    });
    check();
    await _storage.write(key: key, value: raw);
    check();
    if (await _storage.read(key: key) != raw) {
      throw const VncFailure('storage_failed');
    }
    check();
    if (_namespace.allowsLegacyLocal) {
      await _storage.delete(key: _legacyKey(target));
      check();
      if (await _storage.read(key: _legacyKey(target)) != null) {
        throw const VncFailure('storage_failed');
      }
      check();
    }
  }

  @override
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (_) async {});

  @override
  Future<VncCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    final value = await _read(profile, check);
    if (value == null) return null;
    return VncCertificatePin.fromJson({
      'algorithm': value['algorithm'],
      'fingerprint': value['fingerprint'],
    });
  });

  @override
  Future<void> trust(
    RemoteProfile profile,
    VncCertificatePin value, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    value.validate();
    if (await _read(profile, check) != null) {
      throw const VncFailure('certificate_already_pinned');
    }
    await _write(profile, value, check);
  });

  /// Deletes only this source namespace and exact profile binding.
  Future<void> forgetProfileRecords(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent);
    final target = reference(profile);
    return ConfigurationWrites.run(() async {
      try {
        for (final key in [
          _key(target),
          if (_namespace.allowsLegacyLocal) _legacyKey(target),
        ]) {
          check();
          await _storage.delete(key: key);
          check();
          if (await _storage.read(key: key) != null) {
            throw const VncFailure('storage_failed');
          }
          check();
        }
      } on VncFailure {
        rethrow;
      } catch (_) {
        check();
        throw const VncFailure('storage_failed');
      }
    });
  }
}
