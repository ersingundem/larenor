import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/configuration_writes.dart';
import '../data/remote_profiles.dart';
import '../data/remote_security_namespace.dart';
import 'rdp_models.dart';

typedef RdpProfileValidator = Future<void> Function(
  RemoteProfile profile,
  void Function() check,
);

final class RdpFileTransferAuthority {
  RdpFileTransferAuthority({
    required this.namespaceDigest,
    required this.profileRef,
    required this.profileRevision,
  }) : authorityId = sha256
           .convert(
             utf8.encode(
               'larenor-rdp-saf-authority-v1\u0000$namespaceDigest\u0000'
               '$profileRef\u0000$profileRevision',
             ),
           )
           .toString() {
    final digest = RegExp(r'^[0-9a-f]{64}$');
    if (!digest.hasMatch(namespaceDigest) ||
        !digest.hasMatch(profileRef) ||
        profileRevision < 1 ||
        profileRevision > RdpFileTransferGrant.maximumRevision) {
      throw const RdpFailure('invalid_authority');
    }
  }

  final String namespaceDigest, profileRef, authorityId;
  final int profileRevision;

  Map<String, Object> toWire() => {
    'schemaVersion': 5,
    'namespaceDigest': namespaceDigest,
    'profileRef': profileRef,
    'profileRevision': profileRevision,
  };

  @override
  String toString() => 'RdpFileTransferAuthority(redacted)';
}

final class RdpSecurityNamespace {
  RdpSecurityNamespace._(this.digest, {required this.allowsLegacyLocal});

  factory RdpSecurityNamespace.local() {
    final value = RemoteSecurityNamespace.local();
    return RdpSecurityNamespace._(
      value.digest,
      allowsLegacyLocal: value.allowsLegacyLocal,
    );
  }

  factory RdpSecurityNamespace.coreManaged({
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
      return RdpSecurityNamespace._(
        value.digest,
        allowsLegacyLocal: value.allowsLegacyLocal,
      );
    } on FormatException {
      throw const RdpFailure('invalid_namespace');
    }
  }

  final String digest;
  final bool allowsLegacyLocal;
}

abstract interface class RdpTrustStore {
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<RdpCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<void> trust(
    RemoteProfile profile,
    RdpCertificatePin value, {
    required bool Function() isCurrent,
  });
}

abstract interface class RdpCredentialVault {
  Future<RdpCredential?> readCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<void> saveCredential(
    RemoteProfile profile,
    RdpCredential credential, {
    required bool Function() isCurrent,
  });
  Future<void> deleteCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
}

class RdpSecurityStore implements RdpTrustStore, RdpCredentialVault {
  RdpSecurityStore({
    FlutterSecureStorage? storage,
    RemoteProfilesStore? profiles,
    RdpSecurityNamespace? namespace,
    this.profileValidator,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _profiles = profiles ?? RemoteProfilesStore(),
       _namespace = namespace ?? RdpSecurityNamespace.local();

  final FlutterSecureStorage _storage;
  final RemoteProfilesStore _profiles;
  final RdpSecurityNamespace _namespace;
  final RdpProfileValidator? profileValidator;

  String reference(RemoteProfile profile) =>
      sha256.convert(utf8.encode(jsonEncode(profile.toJson()))).toString();

  RdpFileTransferAuthority fileTransferAuthority(
    RemoteProfile profile, {
    required int profileRevision,
  }) {
    if (profile.protocol != RemoteProtocol.rdp || profile.username.isEmpty) {
      throw const RdpFailure('profile_changed');
    }
    return RdpFileTransferAuthority(
      namespaceDigest: _namespace.digest,
      profileRef: reference(profile),
      profileRevision: profileRevision,
    );
  }

  String fileTransferAuthorityId(
    RemoteProfile profile, {
    required int profileRevision,
  }) => fileTransferAuthority(
    profile,
    profileRevision: profileRevision,
  ).authorityId;
  String _key(String kind, String target) =>
      'rdp_${kind}_v2_${_namespace.digest}_$target';
  String _legacyKey(String kind, String target) => 'rdp_${kind}_v1_$target';

  void Function() _guard(bool Function() current) {
    var retired = false;
    return () {
      try {
        if (!retired && current()) return;
      } catch (_) {}
      retired = true;
      throw const RdpFailure('retired');
    };
  }

  Future<void> _profile(RemoteProfile profile, void Function() check) async {
    if (profile.protocol != RemoteProtocol.rdp || profile.username.isEmpty) {
      throw const RdpFailure('profile_changed');
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
      throw const RdpFailure('profile_changed');
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
      } on RdpFailure {
        rethrow;
      } on RemoteProfilesFailure catch (error) {
        throw RdpFailure(
          error.code == 'retired' ? 'retired' : 'profile_changed',
        );
      } catch (_) {
        check();
        throw const RdpFailure('storage_failed');
      }
    });
  }

  Future<Map<String, dynamic>?> _read(
    RemoteProfile profile,
    String kind,
    void Function() check,
  ) async {
    final target = reference(profile);
    check();
    var raw = await _storage.read(key: _key(kind, target));
    check();
    var legacy = false;
    if (raw == null && _namespace.allowsLegacyLocal) {
      raw = await _storage.read(key: _legacyKey(kind, target));
      check();
      legacy = raw != null;
    }
    if (raw == null) return null;
    if (utf8.encode(raw).length > 12288) {
      throw const RdpFailure('invalid_record');
    }
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['version'] != (legacy ? 1 : 2) ||
        value['version'] is! int ||
        value['target'] != target ||
        (!legacy && value['namespace'] != _namespace.digest)) {
      throw const RdpFailure('invalid_record');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<void> _write(
    RemoteProfile profile,
    String kind,
    Map<String, dynamic>? value,
    void Function() check,
  ) async {
    final target = reference(profile);
    final key = _key(kind, target);
    final raw = value == null
        ? null
        : jsonEncode({
            'version': 2,
            'namespace': _namespace.digest,
            'target': target,
            ...value,
          });
    check();
    if (raw == null) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: raw);
    }
    check();
    if (await _storage.read(key: key) != raw) {
      throw const RdpFailure('storage_failed');
    }
    check();
    if (_namespace.allowsLegacyLocal) {
      final legacyKey = _legacyKey(kind, target);
      await _storage.delete(key: legacyKey);
      check();
      if (await _storage.read(key: legacyKey) != null) {
        throw const RdpFailure('storage_failed');
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
  Future<RdpCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    final value = await _read(profile, 'certificate', check);
    if (value == null) return null;
    if ((value.length != 4 && value.length != 5) ||
        value['algorithm'] is! String ||
        value['fingerprint'] is! String) {
      throw const RdpFailure('invalid_record');
    }
    return RdpCertificatePin.fromJson({
      'algorithm': value['algorithm'],
      'fingerprint': value['fingerprint'],
    });
  });

  @override
  Future<void> trust(
    RemoteProfile profile,
    RdpCertificatePin value, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    value.validate();
    if (await _read(profile, 'certificate', check) != null) {
      throw const RdpFailure('certificate_already_pinned');
    }
    await _write(profile, 'certificate', {
      'algorithm': value.algorithm,
      'fingerprint': value.fingerprint,
    }, check);
  });

  Future<RdpProfileSettings> readSettings(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    final value = await _read(profile, 'settings', check);
    if (value == null) return const RdpProfileSettings();
    if ((value.length != 3 && value.length != 4) ||
        !value.containsKey('settings')) {
      throw const RdpFailure('invalid_record');
    }
    return RdpProfileSettings.fromJson(value['settings']);
  });

  Future<void> saveSettings(
    RemoteProfile profile,
    RdpProfileSettings settings, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    final old = await _read(profile, 'settings', check);
    if (old != null) RdpProfileSettings.fromJson(old['settings']);
    await _write(profile, 'settings', {'settings': settings.toJson()}, check);
  });

  @override
  Future<RdpCredential?> readCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    final value = await _read(profile, 'credential', check);
    if (value == null) return null;
    if ((value.length != 4 && value.length != 5) ||
        value['password'] is! String ||
        value['gatewayPassword'] is! String) {
      throw const RdpFailure('invalid_record');
    }
    final result = RdpCredential(
      password: value['password'] as String,
      gatewayPassword: value['gatewayPassword'] as String,
    );
    result.validate();
    return result;
  });

  @override
  Future<void> saveCredential(
    RemoteProfile profile,
    RdpCredential credential, {
    required bool Function() isCurrent,
  }) => _run(profile, isCurrent, (check) async {
    credential.validate();
    final old = await _read(profile, 'credential', check);
    if (old != null) {
      final oldCredential = RdpCredential(
        password: old['password'] is String ? old['password'] as String : '',
        gatewayPassword: old['gatewayPassword'] is String
            ? old['gatewayPassword'] as String
            : '',
      );
      oldCredential.validate();
    }
    await _write(profile, 'credential', {
      'password': credential.password,
      'gatewayPassword': credential.gatewayPassword,
    }, check);
  });

  @override
  Future<void> deleteCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => _run(
    profile,
    isCurrent,
    (check) => _write(profile, 'credential', null, check),
  );

  /// Deletes only records bound to this source namespace and public profile.
  Future<void> forgetProfileRecords(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) {
    final check = _guard(isCurrent);
    final target = reference(profile);
    return ConfigurationWrites.run(() async {
      try {
        for (final kind in const ['certificate', 'settings', 'credential']) {
          for (final key in [
            _key(kind, target),
            if (_namespace.allowsLegacyLocal) _legacyKey(kind, target),
          ]) {
            check();
            await _storage.delete(key: key);
            check();
            if (await _storage.read(key: key) != null) {
              throw const RdpFailure('storage_failed');
            }
            check();
          }
        }
      } on RdpFailure {
        rethrow;
      } catch (_) {
        check();
        throw const RdpFailure('storage_failed');
      }
    });
  }
}
